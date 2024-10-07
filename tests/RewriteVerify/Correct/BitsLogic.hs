module BitsLogic where

import Data.Bits

left_morgan_or :: Int -> Int -> Int
left_morgan_or a b = complement (a .|. b)
right_morgan_or :: Int -> Int -> Int
right_morgan_or a b = ((complement a) .&. (complement b))

{-# RULES 
    "morgans law" forall a b. left_morgan_or a b = right_morgan_or a b 
#-}