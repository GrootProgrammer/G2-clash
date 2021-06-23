{-# LANGUAGE OverloadedStrings #-}

module G2.Equiv.Verifier
    ( verifyLoop
    --, runVerifier
    , checkRule
    ) where

import G2.Language

import G2.Config

import G2.Interface

import qualified Control.Monad.State.Lazy as CM

import qualified G2.Language.ExprEnv as E
import qualified G2.Language.Typing as T

import Data.List
import Data.Maybe
import qualified Data.Text as DT

import qualified Data.HashSet as HS
import qualified G2.Solver as S

import qualified G2.Language.PathConds as P

import G2.Equiv.InitRewrite
import G2.Equiv.EquivADT
import G2.Equiv.G2Calls

import qualified Data.HashMap.Lazy as HM
import Data.Monoid (Any (..))

import Debug.Trace

import G2.Execution.NormalForms
import qualified G2.Language.Stack as Stck
import Control.Monad

import Data.Time

exprReadyForSolver :: ExprEnv -> Expr -> Bool
-- TODO need a Tick case for this now?
-- doesn't seem to make a difference
exprReadyForSolver h (Tick _ e) = exprReadyForSolver h e
exprReadyForSolver h (Var i) = E.isSymbolic (idName i) h && T.isPrimType (typeOf i)
exprReadyForSolver h (App f a) = exprReadyForSolver h f && exprReadyForSolver h a
exprReadyForSolver _ (Prim _ _) = True
exprReadyForSolver _ (Lit _) = True
exprReadyForSolver _ _ = False

statePairReadyForSolver :: (State t, State t) -> Bool
statePairReadyForSolver (s1, s2) =
  let h1 = expr_env s1
      h2 = expr_env s2
      CurrExpr _ e1 = curr_expr s1
      CurrExpr _ e2 = curr_expr s2
  in
  exprReadyForSolver h1 e1 && exprReadyForSolver h2 e2

runSymExec :: Config ->
              StateET ->
              StateET ->
              CM.StateT Bindings IO [(StateET, StateET)]
runSymExec config s1 s2 = do
  let s1' = s1 { rules = [], num_steps = 0 }
      s2' = s2 { rules = [], num_steps = 0 }
  --let s1' = prepareState s1
  --    s2' = prepareState s2
  bindings <- CM.get
  ct <- CM.liftIO $ getCurrentTime
  let config' = config-- { logStates = Just $ "verifier_states/" ++ show ct }
  (er1, bindings') <- CM.lift $ runG2ForRewriteV s1' config' bindings
  CM.put bindings'
  let final_s1 = map final_state er1
  pairs <- mapM (\s1_ -> do
                    b_ <- CM.get
                    ct' <- CM.liftIO $ getCurrentTime
                    let config'' = config-- { logStates = Just $ "verifier_states/" ++ show ct' }
                    let s2_ = transferStateInfo s1_ s2'
                    (er2, b_') <- CM.lift $ runG2ForRewriteV s2_ config'' b_
                    CM.put b_'
                    return $ map (\er2_ -> 
                                    let
                                        s2_' = final_state er2_
                                        s1_' = transferStateInfo s2_' s1_
                                    in
                                    (prepareState s1_', prepareState s2_')
                                 ) er2) final_s1
  return $ concat pairs

-- After s1 has had its expr_env, path constraints, and tracker updated,
-- transfer these updates to s2.
transferStateInfo :: State t -> State t -> State t
transferStateInfo s1 s2 =
    let
        n_eenv = E.union (expr_env s1) (expr_env s2)
    in
    s2 { expr_env = n_eenv
       , path_conds = foldr P.insert (path_conds s1) (P.toList (path_conds s2))
       , symbolic_ids = map (\(Var i) -> i) . E.elems $ E.filterToSymbolic n_eenv
       , track = track s1 }

{-
runVerifier :: S.Solver solver =>
               solver ->
               String ->
               StateET ->
               Bindings ->
               Config ->
               IO (S.Result () ())
runVerifier solver entry init_state bindings config = do
    let tentry = DT.pack entry
        rule = find (\r -> tentry == ru_name r) (rewrite_rules bindings)
        rule' = case rule of
                Just r -> r
                Nothing -> error "not found"
    let (rewrite_state_l, bindings') = initWithLHS init_state bindings $ rule'
        (rewrite_state_r, bindings'') = initWithRHS init_state bindings $ rule'
    let pairs_l = symbolic_ids rewrite_state_l
        pairs_r = symbolic_ids rewrite_state_r
        ns_l = HS.fromList $ E.keys $ expr_env rewrite_state_l
        ns_r = HS.fromList $ E.keys $ expr_env rewrite_state_r
    verifyLoop solver (ns_l, ns_r) (zip pairs_l pairs_r)
               [(rewrite_state_l, rewrite_state_r)]
               [(rewrite_state_l, rewrite_state_r)]
               bindings'' config
-}

frameWrap :: Frame -> Expr -> Expr
frameWrap (CaseFrame i alts) e = Case e i alts
-- TODO which is the function, which is the argument?
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

tickWrap :: Expr -> Expr
tickWrap e = Tick (NamedLoc loc_name) e

exprWrap :: Stck.Stack Frame -> Expr -> Expr
exprWrap sk e = stackWrap sk $ tickWrap e

-- TODO added extra criterion
notEVF :: State t -> Bool
notEVF s = not $ isExprValueForm (expr_env s) (exprExtract s)

pairNotEVF :: (State t, State t) -> Bool
pairNotEVF (s1, s2) = notEVF s1 && notEVF s2

-- TODO tuple or separate arguments?
pairEVF :: (State t, State t) -> Bool
pairEVF (s1, s2) =
  isExprValueForm (expr_env s1) (exprExtract s1) &&
  isExprValueForm (expr_env s2) (exprExtract s2)

eitherEVF :: (State t, State t) -> Bool
eitherEVF (s1, s2) =
  isExprValueForm (expr_env s1) (exprExtract s1) ||
  isExprValueForm (expr_env s2) (exprExtract s2)

-- TODO anything else needs to change?
prepareState :: StateET -> StateET
prepareState s =
  let CurrExpr er e = curr_expr s
  in s {
    curr_expr = CurrExpr er $ exprWrap (exec_stack s) $ e
  , num_steps = 0
  , rules = []
  , exec_stack = Stck.empty
  }

-- TODO
f_name :: Name
-- TODO what is this?
--f_name = Name "f" Nothing 6989586621679188988 Nothing
-- TODO this version comes out as concrete
--f_name = Name "f" Nothing 7566047373982581205 Nothing
-- TODO this comes from the initial state
f_name = Name "f" Nothing 6989586621679189009 (Just (Span {start = Loc {line = 39, col = 20, file = "tests/RewriteVerify/Correct/HigherOrderCorrect.hs"}, end = Loc {line = 39, col = 21, file = "tests/RewriteVerify/Correct/HigherOrderCorrect.hs"}}))

--f = Name "f" Nothing 7566047373982581205 Nothing Just (Conc (Var (Id (Name "f" Nothing 6989586621679189009 (Just (Span {start = Loc {line = 39, col = 20, file = "tests/RewriteVerify/Correct/HigherOrderCorrect.hs"}, end = Loc {line = 39, col = 21, file = "tests/RewriteVerify/Correct/HigherOrderCorrect.hs"}}))) (TyFun (TyCon (Name "Int" (Just "GHC.Types") 8214565720323789235 Nothing) TYPE) (TyCon (Name "Bool" (Just "GHC.Types") 0 Nothing) TYPE))))) True

--Just (Conc (Var (Id (Name "f" Nothing 6989586621679189009 (Just (Span {start = Loc {line = 39, col = 20, file = "tests/RewriteVerify/Correct/HigherOrderCorrect.hs"}, end = Loc {line = 39, col = 21, file = "tests/RewriteVerify/Correct/HigherOrderCorrect.hs"}}))) (TyFun (TyCon (Name "Int" (Just "GHC.Types") 8214565720323789235 Nothing) TYPE) (TyCon (Name "Bool" (Just "GHC.Types") 0 Nothing) TYPE)))))

-- build initial hash set in Main before calling
verifyLoop :: S.Solver solver =>
              solver ->
              (HS.HashSet Name, HS.HashSet Name) ->
              [(Id, Id)] ->
              [(StateET, StateET)] ->
              [(StateET, StateET)] ->
              [(StateET, StateET)] ->
              Bindings ->
              Config ->
              IO (S.Result () ())
verifyLoop solver ns_pair pairs states prev_u prev_g b config | not (null states) = do
    (paired_states, b') <- CM.runStateT (mapM (uncurry (runSymExec config)) states) b
    let vl (s1, s2) = verifyLoop' solver ns_pair s1 s2 prev_u prev_g
    -- TODO
    putStrLn "<Loop Iteration>"
    proof_list <- mapM vl $ concat paired_states
    let proof_list' = [l | Just (_, l) <- proof_list]
        new_obligations = concat proof_list'
        solved_list = concat [l | Just (l, _) <- proof_list]
        -- TODO might not need solved_list
        prev_u' = (filter pairNotEVF $ new_obligations ++ solved_list) ++ prev_u
        --prev_g' = (filter eitherEVF new_obligations ++ solved_list) ++ prev_g
        prev_g' = new_obligations ++ solved_list ++ prev_g
        verified = all isJust proof_list
    putStrLn $ show $ length new_obligations
    if verified then
        verifyLoop solver ns_pair pairs new_obligations prev_u' prev_g' b' config
    else
        return $ S.SAT ()
  | otherwise = do
    return $ S.UNSAT ()

exprExtract :: State t -> Expr
exprExtract (State { curr_expr = CurrExpr _ e }) = e

-- TODO printing
-- TODO how do I tell when to use prev_u or prev_g?
verifyLoop' :: S.Solver solver =>
               solver ->
               (HS.HashSet Name, HS.HashSet Name) ->
               StateET ->
               StateET ->
               [(StateET, StateET)] ->
               [(StateET, StateET)] ->
               IO (Maybe ([(StateET, StateET)], [(StateET, StateET)]))
verifyLoop' solver ns_pair s1 s2 prev_u prev_g =
  let obligation_maybe = obligationStates s1 s2
  in case obligation_maybe of
      Nothing -> do
          putStr "N! "
          putStrLn $ show (exprExtract s1, exprExtract s2)
          return Nothing
      Just obs -> do
          putStr "J! "
          putStrLn $ show (exprExtract s1, exprExtract s2)
          -- TODO
          --putStrLn "$$$"
          --putStrLn $ show $ E.lookupConcOrSym f_name (expr_env s1)
          --putStrLn $ show $ E.lookupConcOrSym f_name (expr_env s2)
          --let prev = if pairNotEVF (s1, s2) then prev_u else prev_g
          -- TODO make sure that this is correct
          let prev = if eitherEVF (s1, s2) then prev_g else prev_u
          --putStr "EVF: "
          --putStrLn $ show $ eitherEVF (s1, s2)
          --putStrLn $ show $ map (\(r1, r2) -> (exprExtract r1, exprExtract r2)) prev
          let obligation_list = filter (not . (moreRestrictivePair ns_pair prev)) obs
              (ready, not_ready) = partition statePairReadyForSolver obligation_list
              ready_exprs = HS.fromList $ map (\(r1, r2) -> (exprExtract r1, exprExtract r2)) ready
          putStr "O: "
          putStrLn $ show ready_exprs
          putStr "NR: "
          putStrLn $ show $ map (\(r1, r2) -> (exprExtract r1, exprExtract r2)) not_ready
          putStr "OBS: "
          putStrLn $ show $ length obs
          res <- checkObligations solver s1 s2 ready_exprs
          case res of
            S.UNSAT () -> putStrLn "V?"
            _ -> putStrLn "X?"
          case res of
            S.UNSAT () -> return $ Just (ready, not_ready)
            _ -> return Nothing

getObligations :: State t -> State t -> Maybe (HS.HashSet (Expr, Expr))
getObligations s1 s2 =
  let CurrExpr _ e1 = curr_expr s1
      CurrExpr _ e2 = curr_expr s2
  in proofObligations s1 s2 e1 e2

-- TODO right way to wrap here?
obligationStates ::  State t -> State t -> Maybe [(State t, State t)]
obligationStates s1 s2 =
  let CurrExpr er1 _ = curr_expr s1
      CurrExpr er2 _ = curr_expr s2
      stateWrap (e1, e2) =
        ( s1 { curr_expr = CurrExpr er1 e1 }
        , s2 { curr_expr = CurrExpr er2 e2 } )
  in case getObligations s1 s2 of
      Nothing -> Nothing
      Just obs -> Just . map stateWrap
                       . map (\(e1, e2) -> (addStackTickIfNeeded e1, addStackTickIfNeeded e2))
                       $ HS.toList obs

addStackTickIfNeeded :: Expr -> Expr
addStackTickIfNeeded e =
    if hasStackTick e then e else tickWrap e

hasStackTick :: Expr -> Bool
hasStackTick = getAny . evalASTs (\e -> case e of
                                          Tick (NamedLoc l) _
                                            | l == loc_name -> Any True
                                          _ -> Any False)

checkObligations :: S.Solver solver =>
                    solver ->
                    State t ->
                    State t ->
                    HS.HashSet (Expr, Expr) ->
                    IO (S.Result () ())
checkObligations solver s1 s2 obligation_set | not $ HS.null obligation_set =
    case obligationWrap obligation_set of
        Nothing -> applySolver solver P.empty s1 s2
        Just allPO -> applySolver solver (P.insert allPO P.empty) s1 s2
  | otherwise = return $ S.UNSAT ()

applySolver :: S.Solver solver =>
               solver ->
               PathConds ->
               State t ->
               State t ->
               IO (S.Result () ())
applySolver solver extraPC s1 s2 =
    let unionEnv = E.union (expr_env s1) (expr_env s2)
        rightPC = P.toList $ path_conds s2
        unionPC = foldr P.insert (path_conds s1) rightPC
        allPC = foldr P.insert unionPC (P.toList extraPC)
        newState = s1 { expr_env = unionEnv, path_conds = allPC }
    in S.check solver newState allPC

obligationWrap :: HS.HashSet (Expr, Expr) -> Maybe PathCond
obligationWrap obligations =
    let obligation_list = HS.toList obligations
        eq_list = map (\(e1, e2) -> App (App (Prim Eq TyUnknown) e1) e2) obligation_list
        -- TODO type issue again
        conj = foldr1 (\o1 o2 -> App (App (Prim And TyUnknown) o1) o2) eq_list
    in
    if null eq_list
    then Nothing
    else Just $ ExtCond (App (Prim Not TyUnknown) conj) True

checkRule :: Config ->
             State t ->
             Bindings ->
             RewriteRule ->
             IO (S.Result () ())
checkRule config init_state bindings rule = do
  let (rewrite_state_l, bindings') = initWithLHS init_state bindings $ rule
      (rewrite_state_r, bindings'') = initWithRHS init_state bindings' $ rule
      pairs_l = symbolic_ids rewrite_state_l
      pairs_r = symbolic_ids rewrite_state_r
      -- convert from State t to StateET
      -- TODO don't have Tick in prev list?
      -- it shouldn't make a difference
      CurrExpr er_l e_l = curr_expr rewrite_state_l
      CurrExpr er_r e_r = curr_expr rewrite_state_r
      rewrite_state_l' = rewrite_state_l {
                           track = emptyEquivTracker
                         , curr_expr = CurrExpr er_l $ tickWrap $ e_l
                         }
      rewrite_state_r' = rewrite_state_r {
                           track = emptyEquivTracker
                         , curr_expr = CurrExpr er_r $ tickWrap $ e_r
                         }
      ns_l = HS.fromList $ E.keys $ expr_env rewrite_state_l
      ns_r = HS.fromList $ E.keys $ expr_env rewrite_state_r
  S.SomeSolver solver <- initSolver config
  putStrLn $ show $ curr_expr rewrite_state_l'
  putStrLn $ show $ curr_expr rewrite_state_r'
  -- TODO do we know that both sides are in SWHNF at the start?
  -- Could that interfere with the results?
  let prev_u = filter pairNotEVF [(rewrite_state_l', rewrite_state_r')]
  res <- verifyLoop solver (ns_l, ns_r) (zip pairs_l pairs_r)
             [(rewrite_state_l', rewrite_state_r')]
             prev_u
             [(rewrite_state_l', rewrite_state_r')]
             bindings'' config
  -- UNSAT for good, SAT for bad
  return res

-- TODO very similar to addSymbolic
symInsert :: Id -> ExprEnv -> ExprEnv
symInsert i = E.insertSymbolic (idName i) i

-- s1 is the old state, s2 is the new state
moreRestrictive :: State t ->
                   State t ->
                   HS.HashSet Name ->
                   HM.HashMap Id Expr ->
                   Expr ->
                   Expr ->
                   Maybe (HM.HashMap Id Expr)
moreRestrictive s1@(State {expr_env = h1}) s2@(State {expr_env = h2}) ns hm e1 e2 =
  case (e1, e2) of
    -- TODO ignore all Ticks
    (Tick _ e1', _) -> moreRestrictive s1 s2 ns hm e1' e2
    (_, Tick _ e2') -> moreRestrictive s1 s2 ns hm e1 e2'
    (Var i1, Var i2) | HS.member (idName i1) ns
                     , idName i1 == idName i2 -> Just hm
    -- TODO new cases, may make some old cases unreachable
    (Var i, _) | not $ E.isSymbolic (idName i) h1
               --, not $ HS.member (idName i) ns
               , Just e <- E.lookup (idName i) h1 -> moreRestrictive s1 s2 ns hm e e2
    (_, Var i) | not $ E.isSymbolic (idName i) h2
               --, not $ HS.member (idName i) ns
               , Just e <- E.lookup (idName i) h2 -> moreRestrictive s1 s2 ns hm e1 e
    (Var i, _) | E.isSymbolic (idName i) h1
               , Nothing <- HM.lookup i hm -> Just (HM.insert i e2 hm)
               | E.isSymbolic (idName i) h1
               , Just e <- HM.lookup i hm
               , e == e2 -> Just hm
               -- this last case means there's a mismatch
               | E.isSymbolic (idName i) h1 -> trace ("CASE A" ++ (mrInfo h1 h2 hm e1 e2)) $ Nothing
               -- non-symbolic cases
               | not $ HS.member (idName i) ns
               , Just e <- E.lookup (idName i) h1 -> moreRestrictive s1 s2 ns hm e e2
               | not $ HS.member (idName i) ns -> error $ "unmapped variable " ++ (show i)
    (_, Var i) | E.isSymbolic (idName i) h2 -> trace ("CASE B" ++ (mrInfo h1 h2 hm e1 e2)) $ Nothing
               -- the case above means sym replaces non-sym
               | Just e <- E.lookup (idName i) h2 -> moreRestrictive s1 s2 ns hm e1 e
               | otherwise -> error "unmapped variable"
    (App f1 a1, App f2 a2) | Just hm_f <- moreRestrictive s1 s2 ns hm f1 f2
                           , Just hm_a <- moreRestrictive s1 s2 ns hm_f a1 a2 -> Just hm_a
                           | otherwise -> {- trace ("CASE C" ++ show ns) $ -} Nothing
    -- We just compare the names of the DataCons, not the types of the DataCons.
    -- This is because (1) if two DataCons share the same name, they must share the
    -- same type, but (2) "the same type" may be represented in different syntactic
    -- ways, most significantly bound variable names may differ
    -- "forall a . a" is the same type as "forall b . b", but fails a syntactic check.
    (Data (DataCon d1 _), Data (DataCon d2 _))
                                  | d1 == d2 -> Just hm
                                  | otherwise -> trace ("CASE D" ++ show d1) $ Nothing
    -- TODO potential problems with type equality checking?
    (Prim p1 t1, Prim p2 t2) | p1 == p2
                             , t1 == t2 -> Just hm
                             | otherwise -> trace ("CASE E" ++ show p1) $ Nothing
    (Lit l1, Lit l2) | l1 == l2 -> Just hm
                     | otherwise -> trace ("CASE F" ++ show l1) $ Nothing
    -- TODO I presume I need syntactic equality for lambda expressions
    -- LamUse is a simple variant
    -- TODO new symbolic variables inserted
    -- TODO what do I use as the name?
    (Lam lu1 i1 b1, Lam lu2 i2 b2)
                | lu1 == lu2
                , i1 == i2 ->
                  let s1' = s1 { expr_env = symInsert i1 h1 }
                      s2' = s2 { expr_env = symInsert i2 h2 }
                  in
                  moreRestrictive s1' s2' ns hm b1 b2
                | otherwise -> trace ("CASE G" ++ show i1) $ Nothing
    -- TODO ignore types, like in exprPairing?
    (Type _, Type _) -> Just hm
    -- TODO add i1 and i2 to the expression environments?
    (Case e1' i1 a1, Case e2' i2 a2)
                | i1 == i2
                , Just hm' <- moreRestrictive s1 s2 ns hm e1' e2' ->
                  -- TODO modify the envs beforehand
                  let h1' = E.insert (idName i1) e1' h1
                      h2' = E.insert (idName i2) e2' h2
                      s1' = s1 { expr_env = h1' }
                      s2' = s2 { expr_env = h2' }
                      mf hm_ (e1_, e2_) = moreRestrictiveAlt s1' s2' ns hm_ e1_ e2_
                      l = zip a1 a2
                  in trace ("CASE BOUND\ne1' = " ++ show e1' ++ "\ne2' = " ++ show e2') foldM mf hm' l
    _ -> {- trace ("CASE H" ++ show (e1, e2)) $ -} Nothing

-- TODO
ds_name :: Name
ds_name = Name "ds" Nothing 8286623314361878754 Nothing

-- TODO
fs_name :: Name
fs_name = Name "fs?" Nothing 16902 Nothing

mrInfo :: ExprEnv ->
          ExprEnv ->
          HM.HashMap Id Expr ->
          Expr ->
          Expr ->
          String
mrInfo h1 h2 hm e1 e2 =
  let a1 = case e1 of
            Var i1 -> (show $ E.isSymbolic (idName i1) h1) ++ ";" ++
                      (show $ HM.lookup i1 hm) ++ ";" ++
                      (show $ E.lookup (idName i1) h1) ++ ";" ++
                      (show e1)
            _ -> show e1
      a2 = case e2 of
            Var i2 -> (show $ E.isSymbolic (idName i2) h2) ++ ";" ++
                      (show $ HM.lookup i2 hm) ++ ";" ++
                      (show $ E.lookup (idName i2) h2) ++ ";" ++
                      (show e2)
            _ -> show e2
      a3 = show $ E.lookup ds_name h1
  in a1 ++ ";;" ++ a2 ++ ";:" ++ a3

-- TODO also add variable mapping to both states
moreRestrictiveAlt :: State t ->
                      State t ->
                      HS.HashSet Name ->
                      HM.HashMap Id Expr ->
                      Alt ->
                      Alt ->
                      Maybe (HM.HashMap Id Expr)
moreRestrictiveAlt s1 s2 ns hm (Alt am1 e1) (Alt am2 e2) =
  if am1 == am2 then
  case (am1, am2) of
    (DataAlt _ t1, DataAlt _ t2) -> let h1 = expr_env s1
                                        h2 = expr_env s2
                                        h1' = foldr symInsert h1 t1
                                        h2' = foldr symInsert h2 t2
                                        s1' = s1 { expr_env = h1' }
                                        s2' = s2 { expr_env = h2' }
                                    in trace ("ALT" ++ (show (t1, t2))) $ moreRestrictive s1' s2' ns hm e1 e2
    _ -> moreRestrictive s1 s2 ns hm e1 e2
  else trace ("CASE I" ++ show am1) Nothing

isMoreRestrictive :: State t ->
                     State t ->
                     HS.HashSet Name ->
                     Bool
isMoreRestrictive s1 s2 ns =
  let CurrExpr _ e1 = curr_expr s1
      CurrExpr _ e2 = curr_expr s2
      -- mr = isJust $ moreRestrictive s1 s2 ns HM.empty e1 e2
  in isJust $ moreRestrictive s1 s2 ns HM.empty e1 e2
  -- trace (show mr) $ trace (show (e1, e2)) $ mr

mrHelper :: State t ->
            State t ->
            HS.HashSet Name ->
            Maybe (HM.HashMap Id Expr) ->
            Maybe (HM.HashMap Id Expr)
mrHelper _ _ _ Nothing = Nothing
mrHelper s1 s2 ns (Just hm) =
  let CurrExpr _ e1 = curr_expr s1
      CurrExpr _ e2 = curr_expr s2
      --res = moreRestrictive s1 s2 ns hm e1 e2
  in moreRestrictive s1 s2 ns hm e1 e2
  --trace (show (isJust res)) res

moreRestrictivePair :: (HS.HashSet Name, HS.HashSet Name) ->
                       [(State t, State t)] ->
                       (State t, State t) ->
                       Bool
moreRestrictivePair (ns1, ns2) prev (s1, s2) =
  let -- mr (p1, p2) = isMoreRestrictive p1 s1 ns1 && isMoreRestrictive p2 s2 ns2
      mr (p1, p2) = isJust $ mrHelper p2 s2 ns2 $ mrHelper p1 s1 ns1 (Just HM.empty)
  in
      trace ("MR: " ++ (show $ not $ null $ filter mr prev)) $
      trace (show $ length prev) $
      (not $ null $ filter mr prev)
      --length (filter mr prev) > 0
