{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}

module Update.Nix.FetchGit
  ( updatesFromFile
  ) where

import           Control.Concurrent.Async     (mapConcurrently)
import           Data.Foldable                (toList)
import           Data.Generics.Uniplate.Data
import           Data.Text                    (pack)
import           Nix.Expr
import           Nix.Parser                   (Result (..), parseNixFileLoc)
import           Update.Nix.FetchGit.Prefetch
import           Update.Nix.FetchGit.Utils
import           Update.Nix.FetchGit.Types
import           Update.Nix.FetchGit.Warning
import           Update.Span

--------------------------------------------------------------------------------
-- Tying it all together
--------------------------------------------------------------------------------

-- | Given the contents of a Nix file, returns the SpanUpdates
-- all the parts of the file we want to update.
updatesFromFile :: FilePath -> IO (Either Warning [SpanUpdate])
updatesFromFile f = do
   e1 <- parseNixFileLoc' f
   e2 <- ioEither (pure . exprToFetchTree) e1
   e3 <- ioEither
     (\t -> sequenceA <$> mapConcurrently getFetchGitLatestInfo t) e2
   ioEither (pure . pure . fetchTreeToSpanUpdates) e3

--------------------------------------------------------------------------------
-- Extracting information about fetches from the AST
--------------------------------------------------------------------------------
ioEither :: (b -> IO (Either a b1)) -> Either a b -> IO (Either a b1)
ioEither = either (pure . Left)

parseNixFileLoc' ::
     FilePath -> IO (Either Warning NExprLoc)
parseNixFileLoc' f =
  parseNixFileLoc f >>= \case
    Failure parseError -> pure $ Left (CouldNotParseInput parseError)
    Success expr -> pure $ Right expr

-- Get a FetchTree from a nix expression.
exprToFetchTree :: NExprLoc -> Either Warning (FetchTree FetchGitArgs)
exprToFetchTree = para exprToFetchTreeCore

exprToFetchTreeCore :: NExprLoc
                    -> [Either Warning (FetchTree FetchGitArgs)]
                    -> Either Warning (FetchTree FetchGitArgs)
exprToFetchTreeCore e subs =
  case e of
      -- If it is a call (application) of fetchgit, record the
      -- arguments since we will need to update them.
      AnnE _ (NApp (AnnE _ (NSym fg)) a)
        | fg `elem` ["fetchgit", "fetchgitPrivate"]
        -> FetchNode <$> extractFetchGitArgs a

      -- If it is an attribute set, find any attributes in it that we
      -- might want to update.
      AnnE _ (NSet bindings)
        -> Node <$> findAttr "version" bindings <*> sequenceA subs

      -- If this is something uninteresting, just wrap the sub-trees.
      _ -> Node Nothing <$> sequenceA subs

-- | Extract a 'FetchGitArgs' from the attrset being passed to fetchgit.
extractFetchGitArgs :: NExprLoc -> Either Warning FetchGitArgs
extractFetchGitArgs = \case
  AnnE _ (NSet bindings) ->
    FetchGitArgs <$> (URL <$> (exprText =<< extractAttr "url" bindings))
                 <*> extractAttr "rev" bindings
                 <*> extractAttr "sha256" bindings
  e -> Left (ArgNotASet e)

--------------------------------------------------------------------------------
-- Getting updated information from the internet.
--------------------------------------------------------------------------------

getFetchGitLatestInfo :: FetchGitArgs -> IO (Either Warning FetchGitLatestInfo)
getFetchGitLatestInfo args = do
  result <- nixPrefetchGit (extractUrlString $ repoLocation args)
  case result of
    Left e -> pure $ Left e
    Right o -> return $ FetchGitLatestInfo args (rev o) (sha256 o)
                                           <$> (parseISO8601DateToDay (date o))

--------------------------------------------------------------------------------
-- Deciding which parts of the Nix file should be updated and how.
--------------------------------------------------------------------------------

fetchTreeToSpanUpdates :: FetchTree FetchGitLatestInfo -> [SpanUpdate]
fetchTreeToSpanUpdates (Node maybeVersionExpr cs) =
  (concatMap fetchTreeToSpanUpdates cs)
  ++ (toList $ maybeVersionExpr >>= maybeUpdateVersion cs)
fetchTreeToSpanUpdates (FetchNode f) = [revUpdate, sha256Update]
  where revUpdate = SpanUpdate (exprSpan (revExpr args))
                               (quoteString (latestRev f))
        sha256Update = SpanUpdate (exprSpan (sha256Expr args))
                                  (quoteString (latestSha256 f))
        args = (originalInfo f)

-- Given a Nix expression representing a version value, and the
-- children of the node that contains it, decides whether and how it
-- should that version string should be updated.  We basically just
-- take the latest date of all the fetches in the children.
maybeUpdateVersion :: [FetchTree FetchGitLatestInfo] -> NExprLoc
                   -> Maybe SpanUpdate
maybeUpdateVersion cs versionExpr =
  case versionDays (Node Nothing cs) of
  [] -> Nothing
  days -> Just $ SpanUpdate (exprSpan versionExpr)
                            ((quoteString . pack . show . maximum) days)

versionDays :: FetchTree FetchGitLatestInfo -> [Day]
versionDays (Node _ cs) = concat (fmap versionDays cs)
versionDays (FetchNode fgli) = [latestDate fgli]
