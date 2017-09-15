module G2.Internals.Interface ( initState
                              , run) where

import G2.Internals.Language

import G2.Internals.Preprocessing.Interface

import G2.Internals.Execution.Interface
import G2.Internals.Execution.Rules

import G2.Internals.SMT.Interface
import G2.Internals.SMT.Language hiding (Assert)

import G2.Internals.Postprocessing.Undefunctionalize

import qualified G2.Internals.Language.ExprEnv as E
import qualified G2.Internals.Language.Stack as Stack
import qualified G2.Internals.Language.SymLinks as Sym
import qualified G2.Internals.Language.Typing


import G2.Lib.Printers

import Data.List
import qualified Data.Map as M

initState :: Program -> [ProgramType] -> Maybe String -> Maybe String -> String -> State
initState prog prog_typ m_assume m_assert f =
    let
        ng = mkNameGen prog
        (ce, ids, ng') = mkCurrExpr m_assume m_assert f (name_gen s) (expr_env s)
        eenv' = mkExprEnv prog


        s = runPreprocessing (State {expr_env = eenv', type_env = mkTypeEnv prog_typ, name_gen = ng})
    in
    State {
      expr_env = foldr (\i@(Id n _) -> E.insertSymbolic n i) (expr_env s) ids
    , type_env = (type_env s)
    , curr_expr = CurrExpr Evaluate ce
    , name_gen = ng'
    , path_conds = map PCExists ids
    , input_ids = ids
    , sym_links = Sym.empty
    , func_table = (func_table s)
    , exec_stack = Stack.empty
 }

mkExprEnv :: Program -> E.ExprEnv
mkExprEnv = E.fromExprList . map (\(i, e) -> (idName i, e)) . concat

mkTypeEnv :: [ProgramType] -> TypeEnv
mkTypeEnv = M.fromList . map (\(n, ts, dcs) -> (n, AlgDataTy ts dcs))

args :: Type -> [Type]
args (TyFun t ts) = t:args ts  
args _ = []

mkCurrExpr :: Maybe String -> Maybe String -> String -> NameGen -> ExprEnv -> (Expr, [Id], NameGen)
mkCurrExpr m_assume m_assert s ng eenv =
    case findFunc s eenv of
        Left (f, ex) -> 
            let
                typs = args . typeOf $ ex
                (names, ng') = freshNames (length typs) ng
                ids = map (uncurry Id) $ zip names typs
                var_ids = reverse $ map Var ids
                
                var_ex = Var f
                app_ex = foldr (\vi e -> App e vi) var_ex var_ids

                (name, ng'') = freshName ng'
                id_name = Id name (typeOf f)
                var_name = Var id_name

                assume_ex = mkAssumeAssert Assume m_assume var_ids var_name var_name eenv
                assert_ex = mkAssumeAssert Assert m_assert var_ids assume_ex var_name eenv
                
                let_ex = Let [(id_name, app_ex)] assert_ex
            in
            (let_ex, ids, ng'')
        Right s -> error s

mkAssumeAssert :: (Expr -> Expr -> Expr) -> Maybe String -> [Expr] -> Expr -> Expr -> ExprEnv -> Expr
mkAssumeAssert p (Just f) var_ids inter pre_ex eenv =
    case findFunc f eenv of
        Left (f, ex) -> 
            let
                app_ex = foldr (\vi e -> App e vi) (Var f) (pre_ex:var_ids)
            in
            p app_ex inter
        Right s -> error s
mkAssumeAssert _ Nothing _ e _ _ = e

findFunc :: String -> ExprEnv -> Either (Id, Expr) String
findFunc s eenv = 
    let
        match = E.toExprList $ E.filterWithKey (\(Name n _ _) _ -> n == s) eenv
    in
    case match of
        [(n, e)] -> Left (Id n (typeOf e) , e)
        x:xs -> Right $ "Multiple functions with name " ++ s
        [] -> Right $ "No functions with name " ++ s


elimNeighboringDups :: Eq a => [a] -> [a]
elimNeighboringDups (x:y:xs) = if x == y then elimNeighboringDups (x:xs) else x:elimNeighboringDups (y:xs)
elimNeighboringDups x = x

run :: SMTConverter ast out io -> io -> Int -> State -> IO [(State, [Expr], Expr)]
run con hhp n state = do

    -- putStrLn . pprExecStateStr $ state

    -- putStrLn "After start"

    -- let preproc_state = runPreprocessing state
    
    -- putStrLn . pprExecStateStr $ preproc_state

    let exec_states = runNBreadthHist [([], state)] n

    -- putStrLn $ "states: " ++ (show $ length exec_states)
    -- mapM_ (\(rs, st) -> putStrLn $ pprExecStateStr st) exec_states
    -- mapM_ (\(rs, st) -> (putStrLn $ pprPathsStr (path_conds st)) >> putStrLn "---") exec_states
    -- mapM_ ((\(rs, st) -> putStrLn (show rs) >> putStrLn (pprExecStateStr st) >> putStrLn "---")) (filter (isExecValueForm . snd) exec_states)

    sm <- satModelOutputs con hhp (map snd exec_states)

    return $ map (\sm@(s, _, _) -> undefunctionalize s sm) sm

    -- ms <- satModelOutputs con hhp (map snd exec_states)

  {-
    let exec_states_error = filter (any (\(r, _) -> r == Just RuleError)) exec_states

    putStrLn ("\nNumber of error states: " ++ (show (length exec_states_error)))
    
    let red_error = map (reverse . elimNeighboringDups) exec_states_error


    mapM_ (mapM_ (\(r, s) -> do
        putStrLn . show $ r
        putStrLn . show . exec_code $ s
        putStrLn "")) red_error

  -}
    -- mapM (putStrLn . pprRunHistStr) exec_states
    
    -- putStrLn ("\nNumber of states: " ++ (show (length exec_states)))

    -- let exec_states = runNDepth [exec_state] n
    -- let states = map (toState preproc_state) exec_states
    -- putStrLn ("\nNumber of execution states: " ++ (show (length states)))
    -- ms <- satModelOutputs con hhp states
    -- mapM (\(m, s) -> putStrLn ("Model:\n" ++ show m ++ "\nSMTAST:\n" ++ show s)) ms
    -- return []

{-
run :: SMTConverter ast out io -> io -> Int -> State -> IO [([Expr], Expr)]
run con hhp n state = do
    let preproc_state = runPreprocessing state

    let states = runNDepth [preproc_state] n

    putStrLn ("\nNumber of execution states: " ++ (show (length states)))


    satModelOutputs con hhp states
-}
