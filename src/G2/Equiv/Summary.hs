{-# LANGUAGE OverloadedStrings #-}

module G2.Equiv.Summary (summarize, summarizeAct) where

-- TODO may not need all imports

import G2.Language

import G2.Config

import G2.Interface

import qualified G2.Language.ExprEnv as E
import qualified G2.Language.Expr as X

import Data.List
import Data.Maybe

import G2.Equiv.InitRewrite
import G2.Equiv.EquivADT
import G2.Equiv.G2Calls
import G2.Equiv.Tactics

import G2.Execution.Memory

import Debug.Trace

import G2.Execution.NormalForms
import Control.Monad

import Data.Time

import G2.Execution.Reducer
import G2.Lib.Printers

sideName :: Side -> String
sideName ILeft = "Left"
sideName IRight = "Right"

trackName :: StateET -> String
trackName s =
  let str = folder_name $ track s
  in case str of
    "" -> "Start"
    _ -> str

printPG :: PrettyGuide -> [Name] -> StateET -> String
printPG pg ns s =
  let h = expr_env s
      e_str = printHaskellPG pg s $ exprExtract s
      var_str = printVars pg ns s
  in case var_str of
    "" -> e_str ++ "\n---"
    _ -> e_str ++ "\nVariables:\n" ++ var_str ++ "\n---"

data ChainEnd = Symbolic
              | Cycle Id
              | Terminal Expr [Id]
              | Unmapped

-- don't include ns names in the result here
-- TODO remove duplicates here?
varsInExpr :: [Name] -> Expr -> [Id]
varsInExpr ns e = filter (\i -> not ((idName i) `elem` ns)) $ X.vars e

extraVars :: ChainEnd -> [Id]
extraVars (Terminal _ ids) = ids
extraVars _ = []

-- new function for getting all of the variables right away
-- some of the computations here are redundant with what happens later
-- need to prune out repeats
-- should things count as repeats if they appear in the chain?
-- TODO remove duplicates
varsFull :: ExprEnv -> [Name] -> Expr -> [Id]
varsFull h ns e =
  let vs = varsInExpr ns e
      chains = map (varChain h ns []) vs
      extras = concat $ map (extraVars . snd) chains
      -- throw out the ones that we covered already
      extras' = filter (\i -> not (i `elem` vs)) extras
      -- get the var chains of these, with ns extended
      ns' = (map idName vs) ++ ns
      extras_full = concat $ map (\i -> varsFull h ns' $ Var i) extras'
  in vs ++ extras_full

-- the terminal expression can have variables of its own that we should cover
varChain :: ExprEnv -> [Name] -> [Id] -> Id -> ([Id], ChainEnd)
varChain h ns inlined i =
  if i `elem` inlined then (reverse inlined, Cycle i)
  else if (idName i) `elem` ns then (reverse inlined, Terminal (Var i) [])
  else case E.lookupConcOrSym (idName i) h of
    Nothing -> ([], Unmapped)
    Just (E.Sym i') -> (reverse (i':inlined), Symbolic)
    Just (E.Conc e) -> exprChain h ns (i:inlined) e

exprChain :: ExprEnv -> [Name] -> [Id] -> Expr -> ([Id], ChainEnd)
exprChain h ns inlined e = case e of
  Tick _ e' -> exprChain h ns inlined e'
  Var i -> varChain h ns inlined i
  _ -> (reverse inlined, Terminal e $ varsInExpr ns e)

-- stop inlining when something in ns reached
-- TODO not the best case setup
printVar :: PrettyGuide -> [Name] -> StateET -> Id -> String
printVar pg ns s@(State{ expr_env = h }) i =
  let (chain, c_end) = varChain h ns [] i
      chain_strs = map (\i_ -> printHaskellPG pg s $ Var i_) chain
      end_str = case c_end of
        Symbolic -> "Symbolic"
        Cycle i' -> "Cycle " ++ printHaskellPG pg s (Var i')
        Terminal e _ -> printHaskellPG pg s e
        Unmapped -> ""
  in case c_end of
    Unmapped -> ""
    _ -> (foldr (\str acc -> str ++ " -> " ++ acc) "" chain_strs) ++ end_str

-- TODO will this alter order?
printVars :: PrettyGuide -> [Name] -> StateET -> String
printVars pg ns s =
  let vars = nub $ varsFull (expr_env s) ns (exprExtract s)
      var_strs = map (printVar pg ns s) vars
      non_empty_strs = filter (not . null) var_strs
  in intercalate "\n" non_empty_strs

-- no new line at end
summarizeStatePairTrack :: String ->
                           PrettyGuide ->
                           [Name] ->
                           StateET ->
                           StateET ->
                           String
summarizeStatePairTrack str pg ns s1 s2 =
  str ++ ": " ++
  (trackName s1) ++ ", " ++
  (trackName s2) ++ "\n" ++
  (printPG pg ns s1) ++ "\n" ++
  (printPG pg ns s2)

-- TODO print the name differently?
summarizeInduction :: PrettyGuide -> [Name] -> IndMarker -> String
summarizeInduction pg ns im@(IndMarker {
                           ind_real_present = (s1, s2)
                         , ind_used_present = (q1, q2)
                         , ind_past = (p1, p2)
                         , ind_result = (s1', s2')
                         , ind_present_scrutinees = (e1, e2)
                         , ind_past_scrutinees = (r1, r2)
                         }) =
  "Induction:\n" ++
  (summarizeStatePairTrack "Real Present" pg ns s1 s2) ++ "\n" ++
  (summarizeStatePairTrack "Used Present" pg ns q1 q2) ++ "\n" ++
  (summarizeStatePairTrack "Past" pg ns p1 p2) ++ "\n" ++
  "Side: " ++ (sideName $ ind_side im) ++ "\n" ++
  "Result:\n" ++
  (printPG pg ns s1') ++ "\n" ++
  (printPG pg ns s2') ++ "\n" ++
  "Present Sub-Expressions Used for Induction:\n" ++
  (printHaskellPG pg q1 e1) ++ "\n" ++
  (printHaskellPG pg q2 e2) ++ "\n" ++
  "Past Sub-Expressions Used for Induction:\n" ++
  (printPG pg ns r1) ++ "\n" ++
  (printPG pg ns r2) ++ "\n" ++
  "New Variable Name: " ++ (show $ ind_fresh_name im)

summarizeCoinduction :: PrettyGuide -> [Name] -> CoMarker -> String
summarizeCoinduction pg ns (CoMarker {
                             co_real_present = (s1, s2)
                           , co_used_present = (q1, q2)
                           , co_past = (p1, p2)
                           }) =
  "Coinduction:\n" ++
  (summarizeStatePairTrack "Real Present" pg ns s1 s2) ++ "\n" ++
  (summarizeStatePairTrack "Used Present" pg ns q1 q2) ++ "\n" ++
  (summarizeStatePairTrack "Past" pg ns p1 p2)

-- variables:  find all names used in here
-- look them up, find a fixed point
-- print all relevant vars beside the expressions
-- don't include definitions from the initial state (i.e. things in ns)
summarizeEquality :: PrettyGuide -> [Name] -> EqualMarker -> String
summarizeEquality pg ns (EqualMarker {
                          eq_real_present = (s1, s2)
                        , eq_used_present = (q1, q2)
                        }) =
  "Equivalent Expressions:\n" ++
  (summarizeStatePairTrack "Real Present" pg ns s1 s2) ++ "\n" ++
  (summarizeStatePairTrack "Used States" pg ns q1 q2)

summarizeNoObligations :: PrettyGuide -> [Name] -> (StateET, StateET) -> String
summarizeNoObligations = summarizeStatePair "No Obligations Produced"

summarizeNotEquivalent :: PrettyGuide -> [Name] -> (StateET, StateET) -> String
summarizeNotEquivalent = summarizeStatePair "NOT EQUIVALENT"

summarizeSolverFail :: PrettyGuide -> [Name] -> (StateET, StateET) -> String
summarizeSolverFail = summarizeStatePair "SOLVER FAIL"

summarizeUnresolved :: PrettyGuide -> [Name] -> (StateET, StateET) -> String
summarizeUnresolved = summarizeStatePair "Unresolved"

summarizeStatePair :: String ->
                      PrettyGuide ->
                      [Name] ->
                      (StateET, StateET) ->
                      String
summarizeStatePair str pg ns (s1, s2) =
  str ++ ":\n" ++
  (trackName s1) ++ ", " ++
  (trackName s2) ++ "\n" ++
  (printPG pg ns s1) ++ "\n" ++
  (printPG pg ns s2)

summarizeAct :: PrettyGuide -> [Name] -> ActMarker -> String
summarizeAct pg ns m = case m of
  Induction im -> summarizeInduction pg ns im
  Coinduction cm -> summarizeCoinduction pg ns cm
  Equality em -> summarizeEquality pg ns em
  NoObligations s_pair -> summarizeNoObligations pg ns s_pair
  NotEquivalent s_pair -> summarizeNotEquivalent pg ns s_pair
  SolverFail s_pair -> summarizeSolverFail pg ns s_pair
  Unresolved s_pair -> summarizeUnresolved pg ns s_pair

tabsAfterNewLines :: String -> String
tabsAfterNewLines [] = []
tabsAfterNewLines ('\n':t) = '\n':'\t':(tabsAfterNewLines t)
tabsAfterNewLines (c:t) = c:(tabsAfterNewLines t)

-- generate the guide for the whole summary externally
summarize :: PrettyGuide -> [Name] -> Marker -> String
summarize pg ns (Marker (sh1, sh2) m) =
  let names1 = map trackName $ (latest sh1):history sh1
      names2 = map trackName $ (latest sh2):history sh2
  in
  "***\nLeft Path: " ++
  (intercalate " -> " $ (reverse names1)) ++
  "\nRight Path: " ++
  (intercalate " -> " $ (reverse names2)) ++ "\n" ++
  (tabsAfterNewLines $ summarizeAct pg ns m)
