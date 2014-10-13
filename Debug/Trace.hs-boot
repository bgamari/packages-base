{-# LANGUAGE NoImplicitPrelude #-}

module Debug.Trace (traceEventIO) where

import GHC.Types

traceEventIO :: [Char] -> IO ()
