module G2.Internals.Execution.Support
    ( ExecState(..)
    , fromState
    , toState

    , Symbol(..)
    , ExecStack
    , Frame(..)
    , ExecExprEnv
    , EnvObj(..)
    , ExecCode(..)
    , ExecCond(..)

    , pushExecStack
    , popExecStack

    , lookupExecExprEnv
    , insertEnvObj
    , insertEnvObjs
    , insertRedirect
    ) where

import G2.Internals.Language

import qualified Data.Map as M

-- | The execution state that we keep track of is different than the regular
-- G2 state. This is because for execution we need more complicated data
-- structures to make things more run smoothly in the rule reductions. However
-- there are `fromState` and `toState` functions provided to extract and inject
-- back the original values from `State`.
data ExecState = ExecState { exec_stack :: ExecStack
                           , exec_eenv :: ExecExprEnv
                           , exec_code :: ExecCode
                           , exec_names :: NameGen
                           , exec_paths :: [ExecCond]
                           } deriving (Show, Eq, Read)

-- | Convert `PathCond` to `ExecCond`.
condToExecCond :: PathCond -> ExecCond
condToExecCond (AltCond am expr b) = ExecAltCond am expr b empty_exec_eenv
condToExecCond (ExtCond expr b) = ExecExtCond expr b empty_exec_eenv

-- | `ExprEnv` kv pairs to `ExecExprEnv`'s.
eenvToExecEnv :: ExprEnv -> ExecExprEnv
eenvToExecEnv = ExecExprEnv . M.map (Right . ExprObj)

-- | `State` to `ExecState`.
fromState :: State -> ExecState
fromState State { expr_env = eenv
                , curr_expr = expr
                , name_gen = confs
                , path_conds = paths } = exec_state
  where
    exec_state = ExecState { exec_stack = empty_exec_stack
                           , exec_eenv = ex_eenv
                           , exec_code = ex_code
                           , exec_names = confs
                           , exec_paths = ex_paths }
    ex_eenv = eenvToExecEnv eenv
    ex_code = Evaluate expr
    ex_paths = map condToExecCond paths

-- | `ExecState` to `State`.
toState :: State -> ExecState -> State
toState s e_s = State { expr_env = undefined
                      , type_env = type_env s
                      , curr_expr = execCodeExpr . exec_code $ e_s
                      , name_gen = name_gen s
                      , path_conds = undefined
                      , sym_links = sym_links s
                      , func_table = func_table s }

-- | Symbolic values have an `Id` for their name, as well as an optional
-- scoping context to denote what they are derived from.
data Symbol = Symbol Id (Maybe (Expr, ExecExprEnv)) deriving (Show, Eq, Read)

-- | The reason hy Haskell does not enable stack traces by default is because
-- the notion of a function call stack does not really exist in Haskell. The
-- stack is a combination of update pointers, application frames, and other
-- stuff!
newtype ExecStack = ExecStack [Frame] deriving (Show, Eq, Read)

-- | These are stack frames.
-- * Case frames contain an `Id` for which to bind the inspection expression,
--     a list of `Alt`, and a `ExecExprEnv` in which this `CaseFrame` happened.
--     `CaseFrame`s are generated as a result of evaluating `Case` expressions.
-- * Application frames contain a single expression and its `ExecExprEnv`.
--     These are generated by `App` expressions.
-- * Update frames contain the `Name` on which to inject a new thing into the
--     expression environment after the current expression is done evaluating.
data Frame = CaseFrame Id [Alt] ExecExprEnv
           | ApplyFrame Expr
           | UpdateFrame Name
           deriving (Show, Eq, Read)

-- | From a user perspective, `ExecExprEnv`s are mappings from `Name` to
-- `EnvObj`s. however, because redirection pointers are included, this
-- complicates things. Instead, we use the `Either` type to separate
-- redirection and actual objects, so by using the supplied lookup functions,
-- the user should never be returned a redirection pointer from `ExecExprEnv`
-- lookups.
newtype ExecExprEnv = ExecExprEnv (M.Map Name (Either Name EnvObj))
                    deriving (Show, Eq, Read)

-- | Environment objects can either by some expression object, or a symbolic
-- object that has been computed before. Lastly, they can be BLACKHOLEs that
-- Simon Peyton Jones claims to stop certain types of bad evaluations.
data EnvObj = ExprObj Expr
            | SymObj Symbol
            | BLACKHOLE
            deriving (Show, Eq, Read)

-- | `ExecCode` is the current expression we have. We are either evaluating it, or
-- it is in some terminal form that is simply returned. Technically we do not
-- need to make this distinction and can simply call a `isTerm` function or
-- equivalent to check, but this makes clearer distinctions for writing the
-- evaluation code.
data ExecCode = Evaluate Expr
              | Return Expr
              deriving (Show, Eq, Read)

execCodeExpr :: ExecCode -> Expr
execCodeExpr (Evaluate e) = e
execCodeExpr (Return e) = e

-- | The current logical conditions up to our current path of execution.
-- Here the `ExecAltCond` denotes conditions from matching on data constructors
-- in `Case` statements, while `ExecExtCond` is from external conditions. These
-- are similar to their `State` counterparts, but are now augmented with a
-- `ExecExprEnv` to allow for further reduction later on / accurate referencing with
-- respect to their environment at the time of creation.
data ExecCond = ExecAltCond AltMatch Expr Bool ExecExprEnv
              | ExecExtCond Expr Bool ExecExprEnv
              deriving (Show, Eq, Read)

-- | `foldr` helper function that takes (A, B) into A -> B type inputs.
foldrPair :: (a -> b -> c -> c) -> (a, b) -> c -> c
foldrPair f (a, b) c = f a b c

-- | Empty `ExecStack`.
empty_exec_stack :: ExecStack
empty_exec_stack = ExecStack []

-- | Push a `Frame` onto the `ExecStack`.
pushExecStack :: Frame -> ExecStack -> ExecStack
pushExecStack frame (ExecStack frames) = ExecStack (frame : frames)

-- | Pop a `Frame` from the `ExecStack`, should it exist.
popExecStack :: ExecStack -> Maybe (Frame, ExecStack)
popExecStack (ExecStack []) = Nothing
popExecStack (ExecStack (frame:frames)) = Just (frame, ExecStack frames)

-- | Empty `ExecExprEnv`.
empty_exec_eenv :: ExecExprEnv
empty_exec_eenv = ExecExprEnv M.empty

-- | Lookup an `EnvObj` in the `ExecExprEnv` by `Name`.
lookupExecExprEnv :: Name -> ExecExprEnv -> Maybe EnvObj
lookupExecExprEnv name (ExecExprEnv smap) = case M.lookup name smap of
    Just (Left redir) -> lookupExecExprEnv redir (ExecExprEnv smap)
    Just (Right eobj) -> Just eobj
    Nothing -> Nothing

-- | Insert an `EnvObj` into the `ExecExprEnv`.
insertEnvObj :: Name -> EnvObj -> ExecExprEnv -> ExecExprEnv
insertEnvObj k v (ExecExprEnv smap) = ExecExprEnv (M.insert k (Right v) smap)

-- | Insert multiple `EnvObj`s into the `ExecExprEnv`.
insertEnvObjs :: [(Name, EnvObj)] -> ExecExprEnv -> ExecExprEnv
insertEnvObjs kvs scope = foldr (foldrPair insertEnvObj) scope kvs

-- | Insert `ExecExprEnv` redirection. We make the left one point to where the
-- right one is pointing at.
insertRedirect :: Name -> Name -> ExecExprEnv -> ExecExprEnv
insertRedirect k r (ExecExprEnv smap) = ExecExprEnv (M.insert k (Left r) smap)

