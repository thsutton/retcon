{-# LANGUAGE DeriveFunctor #-}
------------------------------------------------------------------------
-- |
-- Module      : Retcon.Diff
-- Description : Represent, build and apply diffs over documents.
-- Copyright   : Anchor Systems and others.
-- License     : BSD3
--
-- Maintainer  : Thomas Sutton <me@thomas-sutton.id.au>
-- Stability   : experimental
-- Portability : portable
--
-- This module implements the 'Diff' and 'DiffOp' data styles which
-- together model the changes between 'Document's. Both diffs and the
-- operations which compose them can be labelled with arbitary values.
------------------------------------------------------------------------
module Retcon.Diff where

import           Data.Text (Text)
import qualified Data.Text as T

import Retcon.Document

-- | A 'Diff' describes a collection of changes to a 'Document'.
data Diff l = Diff
  { diffLabel   :: l
  , diffChanges :: [DiffOp l]
  }
  deriving (Eq, Show, Functor)

-- | A 'DiffOp' describes a single change to be applied to a 'Document'.
data DiffOp l
  = InsertOp l [DocumentKey] Text -- ^ Set a field to a value.
  | DeleteOp l [DocumentKey]      -- ^ Unset a field.
  deriving (Eq, Show, Functor)

-- | Generate a 'Diff' from two documents, with a void label.
diff :: Document -- ^ Source document.
     -> Document -- ^ Target document.
     -> Diff ()
diff = diffWith (const ())

-- | Generate a 'Diff' from two documents, using the supplied function
-- to extract a label.
diffWith :: (Document -> l) -- ^ Extract a label from target document
         -> Document        -- ^ Source document.
         -> Document        -- ^ Target document.
         -> Diff l
diffWith label from to = error "Unable to generate diffs"
