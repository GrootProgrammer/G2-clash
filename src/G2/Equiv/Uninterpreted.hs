{-# LANGUAGE  FlexibleContexts #-}


module G2.Equiv.Uninterpreted where 
 
import G2.Language
import qualified G2.Language.ExprEnv as E
import Data.Foldable
import Data.Maybe 
import qualified Data.HashMap.Lazy as HM 
import Data.List  
import qualified G2.Language.TypeEnv as T

-- | Find variables that don't have binding and adjust the epxression environment to treat them as symbolic 
addFreeVarsAsSymbolic :: ExprEnv -> ExprEnv 
addFreeVarsAsSymbolic eenv = let xs = freeVars eenv eenv 
                             in foldl' (flip E.insertSymbolic) eenv xs 

allDC :: ASTContainer t Expr => t -> [DataCon]
allDC = evalASTs allDC' 

-- problem: not generate one list but two separate list
allDC' :: Expr -> [DataCon]
allDC' e = case e of 
    Data dc -> [dc] 
    Case _ _ _ as -> mapMaybe (\(Alt altMatch _) -> case altMatch of 
                                                        DataAlt dc _ -> Just dc
                                                        _ -> Nothing) as 
    _ -> []


-- difference from Data.HashMap.Lazy
-- get all algDataType with elems and  get the DataCon out of a AlgDataTy
--- in e 
freeDC :: ASTContainer e Expr => TypeEnv -> e -> [DataCon]
freeDC typeEnv e = allDC e \\ (concatMap dataCon . HM.elems $ typeEnv)

allTypes :: ASTContainer t Type => t -> [(Name, Kind)]
allTypes = evalASTs allTypes' 

allTypes' :: Type -> [(Name, Kind)]
allTypes' t = case t of 
        TyCon n k -> [(n,k)]
        _ -> []

-- argTypesTEnv :: TypeEnv -> [Type]
-- problem with the types we got list of pair instead of list of [(Name,Kind)]
freeTypes :: ASTContainer t Type => TypeEnv -> t -> [(Name, Kind)]
freeTypes typeEnv t = HM.toList $ HM.difference (HM.fromList $ allTypes t) typeEnv 
