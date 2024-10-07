module BitsLogic where

import Data.Bits

left_morgan_or :: Int -> Int -> Int
left_morgan_or a b = complement (a .|. b)
right_morgan_or :: Int -> Int -> Int
right_morgan_or a b = ((complement a) .&. (complement b))


left_morgan_and :: Int -> Int -> Int
left_morgan_and a b = complement (a .&. b)
right_morgan_and :: Int -> Int -> Int
right_morgan_and a b = ((complement a) .|. (complement b))

{-# RULES 
"morgans law or" forall a b. left_morgan_or a b = right_morgan_or a b 
"morgans law and" forall a b. left_morgan_and a b = right_morgan_and a b 
#-}