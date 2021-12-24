{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}

module G2.Equiv.Verifier
    ( verifyLoop
    , checkRule
    ) where

import G2.Language

import G2.Config

import G2.Interface

import qualified Control.Monad.State.Lazy as CM

import qualified G2.Language.ExprEnv as E
import qualified G2.Language.Typing as T
import qualified G2.Language.CallGraph as G

import Data.List
import Data.Maybe
import qualified Data.Text as DT

import qualified Data.HashSet as HS
import qualified G2.Solver as S

import qualified G2.Language.PathConds as P

import G2.Equiv.InitRewrite
import G2.Equiv.EquivADT
import G2.Equiv.G2Calls
import G2.Equiv.Tactics
import G2.Equiv.Induction
import G2.Equiv.Summary

import qualified Data.HashMap.Lazy as HM
import qualified Data.Map as M
import G2.Execution.Memory
import Data.Monoid (Any (..))

import Debug.Trace

import G2.Execution.NormalForms
import qualified G2.Language.Stack as Stck
import Control.Monad

import Data.Time

import G2.Execution.Reducer
import G2.Lib.Printers

-- TODO reader / writer monad source consulted
-- https://mmhaskell.com/monads/reader-writer

import qualified Control.Monad.Writer.Lazy as W

-- 9/27 notes
-- TODO have a list of every single state, not just the stopping ones
-- The value of discharge should be the previously-encountered state pair that
-- was used to discharge this branch, if the branch has been discharged.
-- TODO requiring finiteness for forceIdempotent makes verifier get stuck
-- same goes for p10 in Zeno

statePairReadyForSolver :: (State t, State t) -> Bool
statePairReadyForSolver (s1, s2) =
  let h1 = expr_env s1
      h2 = expr_env s2
      CurrExpr _ e1 = curr_expr s1
      CurrExpr _ e2 = curr_expr s2
  in
  exprReadyForSolver h1 e1 && exprReadyForSolver h2 e2

-- don't log when the base folder name is empty
logStatesFolder :: String -> String -> LogMode
logStatesFolder _ "" = NoLog
logStatesFolder pre fr = Log Pretty $ fr ++ "/" ++ pre

logStatesET :: String -> String -> String
logStatesET pre fr = fr ++ "/" ++ pre

-- TODO keep a single solver rather than making a new one each time
-- TODO connection between Solver and SomeSolver?
runSymExec :: S.Solver solver =>
              solver ->
              Config ->
              String ->
              StateET ->
              StateET ->
              CM.StateT (Bindings, Int) IO [(StateET, StateET)]
runSymExec solver config folder_root s1 s2 = do
  CM.liftIO $ putStrLn "runSymExec"
  ct1 <- CM.liftIO $ getCurrentTime
  (bindings, k) <- CM.get
  let config' = config { logStates = logStatesFolder ("a" ++ show k) folder_root }
      t1 = (track s1) { folder_name = logStatesET ("a" ++ show k) folder_root }
      -- TODO always Evaluate here?
      CurrExpr r1 e1 = curr_expr s1
      e1' = addStackTickIfNeeded e1
      s1' = s1 { track = t1, curr_expr = CurrExpr r1 e1' }
  CM.liftIO $ putStrLn $ (show $ folder_name $ track s1) ++ " becomes " ++ (show $ folder_name t1)
  (er1, bindings') <- CM.lift $ runG2ForRewriteV solver s1' (expr_env s2) (track s2) config' bindings
  CM.put (bindings', k + 1)
  let final_s1 = map final_state er1
  pairs <- mapM (\s1_ -> do
                    (b_, k_) <- CM.get
                    let s2_ = transferTrackerInfo s1_ s2
                    ct2 <- CM.liftIO $ getCurrentTime
                    let config'' = config { logStates = logStatesFolder ("b" ++ show k_) folder_root }
                        t2 = (track s2_) { folder_name = logStatesET ("b" ++ show k_) folder_root }
                        CurrExpr r2 e2 = curr_expr s2_
                        e2' = addStackTickIfNeeded e2
                        s2' = s2_ { track = t2, curr_expr = CurrExpr r2 e2' }
                    CM.liftIO $ putStrLn $ (show $ folder_name $ track s2_) ++ " becomes " ++ (show $ folder_name t2)
                    (er2, b_') <- CM.lift $ runG2ForRewriteV solver s2' (expr_env s1_) (track s1_) config'' b_
                    CM.put (b_', k_ + 1)
                    return $ map (\er2_ -> 
                                    let
                                        s2_' = final_state er2_
                                        s1_' = transferTrackerInfo s2_' s1_
                                    in
                                    (addStamps k $ prepareState s1_', addStamps k_ $ prepareState s2_')
                                 ) er2) final_s1
  CM.liftIO $ filterM (pathCondsConsistent solver) (concat pairs)

pathCondsConsistent :: S.Solver solver =>
                       solver ->
                       (StateET, StateET) ->
                       IO Bool
pathCondsConsistent solver (s1, s2) = do
  res <- applySolver solver P.empty s1 s2
  case res of
    S.UNSAT () -> return False
    _ -> return True

-- Don't share expr env and path constraints between sides
-- info goes from left to right
transferTrackerInfo :: StateET -> StateET -> StateET
transferTrackerInfo s1 s2 =
  let t1 = track s1
      t2 = track s2
      t2' = t2 {
        higher_order = higher_order t1
      , total = total t1
      , finite = finite t1
      }
  in s2 { track = t2' }

frameWrap :: Frame -> Expr -> Expr
frameWrap (CaseFrame i alts) e = Case e i alts
frameWrap (ApplyFrame e') e = App e e'
frameWrap (UpdateFrame _) e = e
frameWrap (CastFrame co) e = Cast e co
frameWrap _ _ = error "unsupported frame"

stackWrap :: Stck.Stack Frame -> Expr -> Expr
stackWrap sk e =
  case Stck.pop sk of
    Nothing -> e
    Just (fr, sk') -> stackWrap sk' $ frameWrap fr e

loc_name :: Name
loc_name = Name (DT.pack "STACK") Nothing 0 Nothing

rec_name :: Name
rec_name = Name (DT.pack "REC") Nothing 0 Nothing

wrapRecursiveCall :: Name -> Expr -> Expr
-- This first case prevents recursive calls from being wrapped twice
wrapRecursiveCall n e@(Tick (NamedLoc n'@(Name t _ _ _)) e') =
  if t == DT.pack "REC"
  then e
  else Tick (NamedLoc n') $ wrapRecursiveCall n e'
wrapRecursiveCall n e@(Var (Id n' _)) =
  if n == n'
  then Tick (NamedLoc rec_name) e
  else wrcHelper n e
wrapRecursiveCall n e = wrcHelper n e

wrcHelper :: Name -> Expr -> Expr
wrcHelper n e = case e of
  Tick (NamedLoc (Name t _ _ _)) _ | t == DT.pack "REC" -> e
  _ -> modifyChildren (wrapRecursiveCall n) e

-- Creating a new expression environment lets us use the existing reachability
-- functions.
-- TODO does the expr env really need to keep track of Lets above this?
-- look inside the bindings and inside the body for recursion
-- TODO I should merge this process with the other wrapping?
-- TODO do I need an extra process for some other recursive structure?
wrapLetRec :: ExprEnv -> Expr -> Expr
wrapLetRec h (Let binds e) =
  let binds1 = map (\(i, e_) -> (idName i, e_)) binds
      fresh_name = Name (DT.pack "FRESH") Nothing 0 Nothing
      h' = foldr (\(n_, e_) h_ -> E.insert n_ e_ h_) h ((fresh_name, e):binds1)
      -- TODO this might be doing more work than is necessary
      wrap_cg = wrapAllRecursion (G.getCallGraph h') h'
      binds2 = map (\(n_, e_) -> (n_, wrap_cg n_ e_)) binds1
      -- TODO will Tick insertions accumulate?
      -- TODO doesn't work, again because nothing reaches fresh_name
      -- should I even need wrapping like this within the body?
      e' = foldr (wrapIfCorecursive (G.getCallGraph h') h' fresh_name) e (map fst binds1)
      -- TODO do I need to do this twice over like this?
      -- doesn't fix the problem of getting stuck
      e'' = wrapLetRec h' $ modifyChildren (wrapLetRec h') e'
      binds3 = map ((wrapLetRec h') . modifyChildren (wrapLetRec h')) (map snd binds2)
      binds4 = zip (map fst binds) binds3
  in
  -- REC tick getting inserted in binds but not in body
  -- it's only needed where the recursion actually happens
  -- need to apply wrap_cg over it with the new names?
  -- wrap_cg with fresh_name won't help because nothing can reach fresh_name
  Let binds4 e''
wrapLetRec h e = modifyChildren (wrapLetRec h) e

-- first Name is the one that maps to the Expr in the environment
-- second Name is the one that might be wrapped
-- do not allow wrapping for symbolic variables
-- modifyChildren can't see a REC tick that was just inserted above it
wrapIfCorecursive :: G.CallGraph -> ExprEnv -> Name -> Name -> Expr -> Expr
wrapIfCorecursive cg h n m e =
  let n_list = G.reachable n cg
      m_list = G.reachable m cg
  in
  if (n `elem` m_list) && (m `elem` n_list)
  then
    if E.isSymbolic m h
    then e
    else wrcHelper m (wrapRecursiveCall m e)
  else e

-- the call graph must be based on the given environment
-- the Name must map to the Expr in the environment
wrapAllRecursion :: G.CallGraph -> ExprEnv -> Name -> Expr -> Expr
wrapAllRecursion cg h n e =
  let n_list = G.reachable n cg
  in
  if (not $ E.isSymbolic n h) && (n `elem` n_list)
  then foldr (wrapIfCorecursive cg h n) e n_list
  else e

tickWrap :: Expr -> Expr
tickWrap (Case e i a) = Case (tickWrap e) i a
tickWrap (App e1 e2) = App (tickWrap e1) e2
tickWrap (Tick nl e) = Tick nl (tickWrap e)
tickWrap e = Tick (NamedLoc loc_name) e

-- stack tick not added here anymore
prepareState :: StateET -> StateET
prepareState s =
  let e = exprExtract s
  in s {
    curr_expr = CurrExpr Evaluate $ stackWrap (exec_stack s) $ e
  , num_steps = 0
  , rules = []
  , exec_stack = Stck.empty
  }

-- "stamps" for Case statements enforce induction validity
stampName :: Int -> Int -> Name
stampName x k =
  Name (DT.pack $ (show x) ++ "STAMP:" ++ (show k)) Nothing 0 Nothing

-- leave existing stamp ticks unaffected; don't cover them with more layers
-- only stamp strings should contain a colon
insertStamps :: Int -> Int -> Expr -> Expr
insertStamps x k (Tick nl e) = Tick nl (insertStamps x k e)
insertStamps x k (Case e i a) =
  case a of
    (Alt am1 a1):as -> case a1 of
        Tick (NamedLoc (Name n _ _ _)) e' | str <- DT.unpack n
                                          , ':' `elem` str ->
          Case (insertStamps (x + 1) k e) i a
        _ -> let sn = stampName x k
                 a1' = Alt am1 (Tick (NamedLoc sn) a1)
             in Case (insertStamps (x + 1) k e) i (a1':as)
    _ -> error "Empty Alt List"
insertStamps _ _ e = e

addStamps :: Int -> StateET -> StateET
addStamps k s =
  let CurrExpr c e = curr_expr s
      e' = insertStamps 0 k e
  in s { curr_expr = CurrExpr c e' }

getLatest :: (StateH, StateH) -> (StateET, StateET)
getLatest (StateH { latest = s1 }, StateH { latest = s2 }) = (s1, s2)

newStateH :: StateET -> StateH
newStateH s = StateH {
    latest = s
  , history = []
  , inductions = []
  , discharge = Nothing
  }

-- discharge only has a meaningful value when execution is done for a branch
appendH :: StateH -> StateET -> StateH
appendH sh s =
  StateH {
    latest = s
  , history = (latest sh):(history sh)
  , inductions = inductions sh
  , discharge = discharge sh
  }

replaceH :: StateH -> StateET -> StateH
replaceH sh s = sh { latest = s }

all_tactics :: S.Solver s => [Tactic s]
all_tactics = [tryEquality, tryCoinduction, inductionFull, trySolver]

data Lemma = Lemma StateET StateET [(StateH, StateH)]

type ProposedLemma = Lemma
type ProvenLemma = Lemma

-- negative loop iteration count means there's no limit
verifyLoop :: S.Solver solver =>
              solver ->
              HS.HashSet Name ->
              [ProposedLemma] ->
              [(StateH, StateH)] ->
              Bindings ->
              Config ->
              String ->
              Int ->
              Int ->
              W.WriterT [Marker] IO (S.Result () ())
verifyLoop solver ns prop_lemmas states b config folder_root k n | n /= 0 = do
  W.liftIO $ putStrLn "<Loop Iteration>"
  W.liftIO $ putStrLn $ show n

  (sr, b', k') <- verifyLoop' solver all_tactics ns b config folder_root k states

  (prop_lemmas', (b'', k'')) <-
              CM.runStateT (mapM (verifyLoopPropLemmas solver all_tactics ns config folder_root) prop_lemmas) (b', k')

  let (proven_lemma, continued_lemmas) = partition (\(sr, _) -> case sr of
                                                                    Proven -> True
                                                                    _ -> False) prop_lemmas'
      proven_lemma' = concatMap snd proven_lemma
      continued_lemmas' = concatMap snd continued_lemmas

  case sr of
      ContinueWith new_obligations new_lemmas -> do
          let n' = if n > 0 then n - 1 else n
          W.liftIO $ putStrLn $ show $ length new_obligations
          W.liftIO $ putStrLn $ "length new_lemmas = " ++ show (length new_lemmas)

          let prop_lemmas'' = continued_lemmas' ++ new_lemmas
          -- mapM (\l@(le1, le2) -> do
          --               let pg = mkPrettyGuide l
          --               W.liftIO $ putStrLn "----"
          --               W.liftIO $ putStrLn $ printPG pg (HS.toList ns) (E.symbolicIds $ expr_env le1) le1
          --               W.liftIO $ putStrLn $ printPG pg (HS.toList ns) (E.symbolicIds $ expr_env le2) le2) $ HS.toList new_lemmas
          verifyLoop solver ns prop_lemmas'' new_obligations b'' config folder_root k'' n'
      CounterexampleFound -> return $ S.SAT ()
      Proven -> return $ S.UNSAT ()
  | otherwise = do
    -- TODO log some new things with the writer for unresolved obligations
    -- TODO the present states are somewhat redundant
    W.liftIO $ putStrLn $ "Unresolved Obligations: " ++ show (length states)
    let ob (sh1, sh2) = Marker (sh1, sh2) $ Unresolved (latest sh1, latest sh2)
    W.tell $ map ob states
    return $ S.Unknown "Loop Iterations Exhausted"

data StepRes = CounterexampleFound
             | ContinueWith [(StateH, StateH)] [Lemma]
             | Proven

verifyLoopPropLemmas :: S.Solver solver =>
                        solver
                     -> [Tactic solver]
                     -> HS.HashSet Name
                     -> Config
                     -> String
                     -> ProposedLemma
                     -> CM.StateT (Bindings, Int)  (W.WriterT [Marker] IO) (StepRes, [Lemma])
verifyLoopPropLemmas solver tactics ns config folder_root l@(Lemma is1 is2 states) = do
    (b, k) <- CM.get
    W.liftIO $ putStrLn $ "k = " ++ show k
    (sr, b', k') <- W.lift (verifyLoop' solver tactics ns b config folder_root k states)
    CM.put (b', k')
    let lem = case sr of
                  CounterexampleFound -> []
                  ContinueWith states' lemmas -> Lemma is1 is2 states':lemmas -- TODO - pass back lemmas also
                  Proven -> [Lemma is1 is2 []] -- TODO - what to return here?
    return (sr, lem)

verifyLoop' :: S.Solver solver =>
               solver
            -> [Tactic solver]
            -> HS.HashSet Name
            -> Bindings
            -> Config
            -> String
            -> Int
            -> [(StateH, StateH)]
            -> W.WriterT [Marker] IO (StepRes, Bindings, Int)
verifyLoop' solver tactics ns b config folder_root k states = do
    let current_states = map getLatest states
    (paired_states, (b', k')) <- W.liftIO $ CM.runStateT (mapM (uncurry (runSymExec solver config folder_root)) current_states) (b, k)

    let (fresh_name, ng') = freshName (name_gen b')
        b'' = b' { name_gen = ng' }
 
        td (sh1, sh2) = tryDischarge solver tactics ns [fresh_name] sh1 sh2

    -- for every internal list, map with its corresponding original state
    let app_pair (sh1, sh2) (s1, s2) = (appendH sh1 s1, appendH sh2 s2)
        map_fns = map app_pair states
        updated_hists = map (uncurry map) (zip map_fns paired_states)
    W.liftIO $ putStrLn $ show $ length $ concat updated_hists
    proof_lemma_list <- mapM td $ concat updated_hists

    let new_obligations = concatMap fst $ catMaybes proof_lemma_list
        new_lemmas = HS.unions . map snd $ catMaybes proof_lemma_list

    let res = if | null proof_lemma_list -> Proven
                 | all isJust proof_lemma_list ->
                      ContinueWith new_obligations (map (uncurry mkProposedLemma) $ HS.toList new_lemmas)
                 | otherwise -> CounterexampleFound
    return (res, b'', k')

mkProposedLemma :: StateET -> StateET -> ProposedLemma
mkProposedLemma s1 s2 = Lemma s1 s2 [(newStateH s1, newStateH s2)] 

stateWrap :: StateET -> StateET -> Obligation -> (StateET, StateET)
stateWrap s1 s2 (Ob e1 e2) =
  ( s1 { curr_expr = CurrExpr Evaluate e1 }
  , s2 { curr_expr = CurrExpr Evaluate e2 } )

-- TODO debugging function
stateHistory :: StateH -> StateH -> [(StateET, StateET)]
stateHistory sh1 sh2 =
  let hist1 = (latest sh1):(history sh1)
      hist2 = (latest sh2):(history sh2)
  in reverse $ zip hist1 hist2

exprTrace :: StateH -> StateH -> [String]
exprTrace sh1 sh2 =
  let s_hist = stateHistory sh1 sh2
      s_pair (s1, s2) = [
          printHaskellDirty (exprExtract s1)
        , printHaskellDirty (exprExtract s2)
        , show (E.symbolicIds $ expr_env s1)
        , show (E.symbolicIds $ expr_env s2)
        , show (track s1)
        , show (track s2)
        , show (length $ inductions sh1)
        , show (length $ inductions sh2)
        --, show (exprExtract s1)
        --, show (exprExtract s2)
        , "------"
        ]
  in concat $ map s_pair s_hist

addDischarge :: StateET -> StateH -> StateH
addDischarge s sh = sh { discharge = Just s }

-- TODO what if n1 or n2 is negative?
adjustStateH :: (StateH, StateH) ->
                (Int, Int) ->
                (StateET, StateET) ->
                (StateH, StateH)
adjustStateH (sh1, sh2) (n1, n2) (s1, s2) =
  let hist1 = drop n1 $ history sh1
      hist2 = drop n2 $ history sh2
      sh1' = sh1 { history = hist1, latest = s1 }
      sh2' = sh2 { history = hist2, latest = s2 }
  in (sh1', sh2')

data TacticEnd = EFail
               | EDischarge
               | EContinue (HS.HashSet (StateET, StateET)) (StateH, StateH)

getRemaining :: TacticEnd -> [(StateH, StateH)] -> [(StateH, StateH)]
getRemaining (EContinue _ sh_pair) acc = sh_pair:acc
getRemaining _ acc = acc

getLemmas :: TacticEnd -> HS.HashSet (StateET, StateET)
getLemmas (EContinue lemmas _) = lemmas
getLemmas _ = HS.empty

hasFail :: [TacticEnd] -> Bool
hasFail [] = False
hasFail (EFail:_) = True
hasFail (_:es) = hasFail es

-- TODO put in a different file?
-- TODO do all of the solver obligations need to be covered together?
trySolver :: S.Solver s => Tactic s
trySolver solver ns _ _ (s1, s2) | statePairReadyForSolver (s1, s2) = do
  let e1 = exprExtract s1
      e2 = exprExtract s2
  res <- W.liftIO $ checkObligations solver s1 s2 (HS.fromList [(e1, e2)])
  case res of
    S.UNSAT () -> return $ Success Nothing
    _ -> return Failure
trySolver _ _ _ _ _ = return $ NoProof HS.empty

-- TODO apply all tactics sequentially in a single run
-- make StateH adjustments between each application, if necessary
-- if Success is ever empty, it's done
-- TODO adjust the output in any way when no tactics remaining?  Yes
-- TODO include the old version in the history or not?
applyTactics :: S.Solver solver =>
                solver ->
                [Tactic solver] ->
                HS.HashSet Name ->
                HS.HashSet (StateET, StateET) ->
                [Name] ->
                (StateH, StateH) ->
                (StateET, StateET) ->
                W.WriterT [Marker] IO TacticEnd
applyTactics solver (tac:tacs) ns lemmas fresh_names (sh1, sh2) (s1, s2) = do
  tr <- tac solver ns fresh_names (sh1, sh2) (s1, s2)
  case tr of
    Failure -> return EFail
    NoProof new_lemmas -> applyTactics solver tacs ns (HS.union new_lemmas lemmas) fresh_names (sh1, sh2) (s1, s2)
    Success res -> case res of
      Nothing -> return EDischarge
      Just (n1, n2, s1', s2') -> do
        let (sh1', sh2') = adjustStateH (sh1, sh2) (n1, n2) (s1', s2')
        applyTactics solver tacs ns lemmas fresh_names (sh1', sh2') (s1', s2')
applyTactics _ _ _ lemmas _ (sh1, sh2) (s1, s2) =
  return $ EContinue lemmas (replaceH sh1 s1, replaceH sh2 s2)

-- TODO how do I handle the solver application in this version?
-- Nothing output means failure now
-- TODO printing
tryDischarge :: S.Solver solver =>
                solver ->
                [Tactic solver] ->
                HS.HashSet Name ->
                [Name] ->
                StateH ->
                StateH ->
                W.WriterT [Marker] IO (Maybe ([(StateH, StateH)], HS.HashSet (StateET, StateET)))
tryDischarge solver tactics ns fresh_names sh1 sh2 =
  let s1 = latest sh1
      s2 = latest sh2
  in case getObligations ns s1 s2 of
    Nothing -> do
      W.tell [Marker (sh1, sh2) $ NotEquivalent (s1, s2)]
      W.liftIO $ putStrLn $ "N! " ++ (show $ folder_name $ track s1) ++ " " ++ (show $ folder_name $ track s2)
      W.liftIO $ putStrLn $ show $ exprExtract s1
      W.liftIO $ putStrLn $ show $ exprExtract s2
      W.liftIO $ mapM putStrLn $ exprTrace sh1 sh2
      return Nothing
    Just obs -> do
      case obs of
        [] -> W.tell [Marker (sh1, sh2) $ NoObligations (s1, s2)]
        _ -> return ()
      W.liftIO $ putStrLn $ "J! " ++ (show $ folder_name $ track s1) ++ " " ++ (show $ folder_name $ track s2)
      W.liftIO $ putStrLn $ printHaskellDirty $ exprExtract s1
      W.liftIO $ putStrLn $ printHaskellDirty $ exprExtract s2
      -- TODO no more limitations on when induction can be used here
      let states = map (stateWrap s1 s2) obs
      res <- mapM (applyTactics solver tactics ns HS.empty fresh_names (sh1, sh2)) states
      -- list of remaining obligations in StateH form
      -- TODO I think non-ready ones can stay as they are
      let res' = foldr getRemaining [] res
          lemmas = HS.unions $ map getLemmas res
      if hasFail res then do
        W.liftIO $ putStrLn "X?"
        W.tell [Marker (sh1, sh2) $ SolverFail (s1, s2)]
        return Nothing
      else do
        W.liftIO $ putStrLn $ "V? " ++ show (length res')
        return $ Just (res', lemmas)

-- TODO (9/27) check path constraint implication?
-- TODO (9/30) alternate:  just substitute one scrutinee for the other
-- put a non-symbolic variable there?

getObligations :: HS.HashSet Name ->
                  State t ->
                  State t ->
                  Maybe [Obligation]
getObligations ns s1 s2 =
  case proofObligations ns s1 s2 (exprExtract s1) (exprExtract s2) of
    Nothing -> Nothing
    Just obs -> Just $ HS.toList obs

addStackTickIfNeeded :: Expr -> Expr
addStackTickIfNeeded e' =
  let has_tick = getAny . evalASTs (\e -> case e of
                                          Tick (NamedLoc l) _
                                            | l == loc_name -> Any True
                                          _ -> Any False) $ e'
  in if has_tick then e' else tickWrap e'

includedName :: [DT.Text] -> Name -> Bool
includedName texts (Name t _ _ _) = t `elem` texts

-- stack tick should appear inside rec tick
startingState :: EquivTracker -> State t -> StateH
startingState et s =
  let h = expr_env s
      -- Tick wrapping for recursive and corecursive functions
      wrap_cg = wrapAllRecursion (G.getCallGraph h) h
      h' = E.map (wrapLetRec h) $ E.mapWithKey wrap_cg h
      all_names = E.keys h
      s' = s {
      track = et
    , curr_expr = CurrExpr Evaluate $ tickWrap $ foldr wrap_cg (exprExtract s) all_names
    , expr_env = h'
    }
  in newStateH s'

unused_name :: Name
unused_name = Name (DT.pack "UNUSED") Nothing 0 Nothing

-- TODO may not use this finiteness-forcing method at all
forceFinite :: Walkers -> Id -> Expr -> Expr
forceFinite w i e =
  let e' = mkStrict w $ Var i
      i' = Id unused_name (typeOf $ Var i)
      a = Alt Default e
  in Case e' i' [a]

cleanState :: State t -> Bindings -> (State t, Bindings)
cleanState state bindings =
  let sym_config = addSearchNames (input_names bindings)
                   $ addSearchNames (M.keys $ deepseq_walkers bindings) emptyMemConfig
  in markAndSweepPreserving sym_config state bindings

checkRule :: Config ->
             State t ->
             Bindings ->
             [DT.Text] -> -- ^ names of forall'd variables required to be total
             [DT.Text] -> -- ^ names of forall'd variables required to be total and finite
             SummaryMode ->
             Int ->
             RewriteRule ->
             IO (S.Result () ())
checkRule config init_state bindings total finite print_summary iterations rule = do
  let (rewrite_state_l, bindings') = initWithLHS init_state bindings $ rule
      (rewrite_state_r, bindings'') = initWithRHS init_state bindings' $ rule
      total_names = filter (includedName total) (map idName $ ru_bndrs rule)
      finite_names = filter (includedName finite) (map idName $ ru_bndrs rule)
      finite_hs = foldr HS.insert HS.empty finite_names
      -- always include the finite names in total
      total_hs = foldr HS.insert finite_hs total_names
      EquivTracker et m _ _ _ = emptyEquivTracker
      start_equiv_tracker = EquivTracker et m total_hs finite_hs ""
      -- the keys are the same between the old and new environments
      ns_l = HS.fromList $ E.keys $ expr_env rewrite_state_l
      ns_r = HS.fromList $ E.keys $ expr_env rewrite_state_r
      -- no need for two separate name sets
      ns = HS.filter (\n -> not (E.isSymbolic n $ expr_env rewrite_state_l)) $ HS.union ns_l ns_r
      -- TODO wrap both sides with forcings for finite vars
      -- get the finite vars first
      -- TODO a little redundant with the earlier stuff
      finite_ids = filter ((includedName finite) . idName) (ru_bndrs rule)
      walkers = deepseq_walkers bindings''
      e_l = exprExtract rewrite_state_l
      e_l' = foldr (forceFinite walkers) e_l finite_ids
      (rewrite_state_l',_) = cleanState (rewrite_state_l { curr_expr = CurrExpr Evaluate e_l' }) bindings
      e_r = exprExtract rewrite_state_r
      e_r' = foldr (forceFinite walkers) e_r finite_ids
      (rewrite_state_r',_) = cleanState (rewrite_state_r { curr_expr = CurrExpr Evaluate e_r' }) bindings
      
      rewrite_state_l'' = startingState start_equiv_tracker rewrite_state_l'
      rewrite_state_r'' = startingState start_equiv_tracker rewrite_state_r'
  S.SomeSolver solver <- initSolver config
  putStrLn $ "***\n" ++ (show $ ru_name rule) ++ "\n***"
  putStrLn $ printHaskellDirty e_l'
  putStrLn $ printHaskellDirty e_r'
  putStrLn $ printHaskellDirty $ exprExtract $ latest rewrite_state_l''
  putStrLn $ printHaskellDirty $ exprExtract $ latest rewrite_state_r''
  (res, w) <- W.runWriterT $ verifyLoop solver ns
             []
             [(rewrite_state_l'', rewrite_state_r'')]
             bindings'' config "" 0 iterations
  -- UNSAT for good, SAT for bad
  if print_summary /= NoSummary then do
    putStrLn "--- SUMMARY ---"
    let pg = mkPrettyGuide $ map (\(Marker _ m) -> m) w
    mapM (putStrLn . (summarize print_summary pg (HS.toList ns) (ru_bndrs rule))) w
    putStrLn "--- END OF SUMMARY ---"
  else return ()
  S.close solver
  return res
