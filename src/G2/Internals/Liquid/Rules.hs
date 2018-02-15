module G2.Internals.Liquid.Rules where

import G2.Internals.Execution.NormalForms
import G2.Internals.Execution.Rules
import G2.Internals.Language
import qualified G2.Internals.Language.ExprEnv as E
import qualified G2.Internals.Language.Stack as S

import qualified Data.Map as M
import Data.Maybe

-- lhReduce
-- When reducing for LH, we change the rule for evaluating Var f.
-- Var f can potentially split into two states.
-- (a) One state is exactly the same as the current reduce function: we lookup
--     up the var, and set the curr expr to its definition.
-- (b) [StateB] The other var is created if the definition of f is of the form:
--     lam x_1 ... lam x_n . let x = f x_1 ... x_n in Assert (a x_1 ... x_n x) x
--
--     We introduce a new symbolic variable x_s, with the same type of s, and
--     set the curr expr to
--     lam x_1 ... lam x_n . let x = x_s in Assert (a x_1 ... x_n x_s) x_s
--
--     This allows us to choose any value for the return type of the function.
--     In this rule, we also return a b, oldb ++ [(f, [x_1, ..., x_n], x)]
--     This is essentially abstracting away the function definition, leaving
--     only the information that LH also knows (that is, the information in the
--     refinment type.)
lhReduce :: State [(Name, [Id], Id)] -> (Rule, [ReduceResult [(Name, [Id], Id)]])
lhReduce = stdReduceBase lhReduce'

lhReduce' :: State [(Name, [Id], Id)] -> Maybe (Rule, [ReduceResult [(Name, [Id], Id)]])
lhReduce' State { expr_env = eenv
               , curr_expr = CurrExpr Evaluate vv@(Var v)
               , name_gen = ng
               , exec_stack = stck }
    | Just expr <- E.lookup (idName v) eenv =
        let
            (r, stck') = if isExprValueForm expr eenv 
                            then ( RuleEvalVarVal (idName v), stck)
                            else ( RuleEvalVarNonVal (idName v)
                                 , S.push (UpdateFrame (idName v)) stck)

            sa = ( eenv
                 , CurrExpr Evaluate expr
                 , []
                 , []
                 , Nothing
                 , ng
                 , stck'
                 , [])

            sb = symbState expr eenv vv ng stck
        in
        Just $ (r, sa:maybeToList sb)
lhReduce' _ = Nothing

-- | symbState
-- See [StateB]
symbState :: Expr -> ExprEnv -> Expr -> NameGen -> S.Stack Frame -> Maybe (ReduceResult [(Name, [Id], Id)])
symbState vv eenv cexpr@(Var (Id n _)) ng stck =
    let
        (i, ng') = freshId (returnType cexpr) ng
        eenv' = E.insertSymbolic (idName i) i eenv

        lIds = leadingLamIds vv
        vv' = stripLams vv
        ((lIds', vv''), ng'') = doRenames (map idName lIds) ng' (lIds, vv')

        (eenv'', stck') = bindArgs lIds' eenv' stck

        cexpr' = symbCExpr i vv''
    in
    case cexpr' of
        Just cexpr'' -> 
            Just (eenv'', CurrExpr Evaluate cexpr'', [], [], Nothing, ng'', stck', [])
        Nothing -> Nothing
symbState _ _ _ _ _ = Nothing

bindArgs :: [Id] -> ExprEnv -> S.Stack Frame -> (ExprEnv, S.Stack Frame)
bindArgs is eenv stck =
    let
        (fs, stck') = S.popN stck (length is)

        eenv' = foldr (uncurry E.insert) eenv $ mapMaybe (uncurry bindArg) $ zip is fs
    in
    (eenv', stck')

bindArg :: Id -> Frame -> Maybe (Name, Expr)
bindArg (Id n _) (ApplyFrame e) = Just (n, e)
bindArg _ _ = Nothing

symbCExpr :: Id -> Expr -> Maybe Expr
symbCExpr i (Let [(b, e)] a@(Assert _ _ (Var b'))) =
    if b == b' 
        then Just $ Let [(b, Var i)] a 
        else Nothing
symbCExpr _ _ = Nothing

stripLams :: Expr -> Expr
stripLams (Lam _ e) = stripLams e
stripLams e = e

argsAndRet :: Expr -> ([Id], Id)
argsAndRet (Lam i e) =
    let
        (is, a) = argsAndRet e
    in
    (i:is, a)
argsAndRet (Let [(b, _)] _) = ([], b)