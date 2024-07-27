{-# LANGUAGE OverloadedStrings #-}

module G2.Translation.HaskellCheck ( validateStates
                                   , runHPC) where

import GHC hiding (Name, entry)
import GHC.Driver.Session

import GHC.LanguageExtensions

import GHC.Paths

import Data.Either
import Data.List
import qualified Data.Text as T
import Text.Regex
import Unsafe.Coerce
import qualified Data.HashMap.Lazy as H
import G2.Initialization.MkCurrExpr
import G2.Interface.OutputTypes
import G2.Language
import G2.Translation.Haskell
import G2.Translation.TransTypes
import G2.Lib.Printers
import Control.Exception

import System.Process
import Debug.Trace

import Control.Monad.IO.Class

validateStates :: [FilePath] -> [FilePath] -> String -> String -> [String] -> [GeneralFlag] -> [ExecRes t] -> IO Bool
validateStates proj src modN entry chAll gflags in_out = do
    return . all id =<< runGhc (Just libdir) (do
        loadToCheck proj src modN gflags
        mapM (runCheck modN entry chAll) in_out)

-- Convert g2 generated types into readable string that aim to notify the environment about the types generated by g2
g2GeneratedTypeToName :: (PrettyGuide, State t) -> (Name, AlgDataTy) -> ((PrettyGuide, State t), String)
g2GeneratedTypeToName (pg, s) (x,y@(DataTyCon{data_cons = dcs, bound_ids = is})) =
    -- "data " ++ show x ++ " " ++ show ids ++ " = " ++ show dcs
    -- data maybe a = just a | nothing
    --  data Name bound_ids = datacons 
    let
        x' = T.unpack $ printName pg x
        ids' = T.unpack . T.intercalate " " $ map (printHaskellPG pg s . Var) is
        dc_name = T.unpack $ printHaskellPG pg s (mkApp $ map Data dcs)
        dc_types = T.unpack . T.intercalate " " $ map mkTypeHaskell (concatMap argumentTypes dcs)
        str = "data " ++ x' ++ " " ++ ids'++ " = " ++ dc_name ++ " " ++ dc_types ++ " deriving Eq"
    in
    trace ("string returned: " ++ show str) ((pg,s), str)
g2GeneratedTypeToName _ _ = error "g2GeneratedTypeToName: unsupported AlgDataTy"

-- Compile with GHC, and check that the output we got is correct for the input
runCheck :: String -> String -> [String] -> ExecRes t -> Ghc Bool
runCheck modN entry chAll (ExecRes {final_state = s, conc_args = ars, conc_out = out}) = do
    (v, chAllR) <- runCheck' modN entry chAll s ars out

    v' <- liftIO $ (unsafeCoerce v :: IO (Either SomeException Bool))
    let outStr = T.unpack $ printHaskell s out
    let v'' = case v' of
                    Left _ -> outStr == "error"
                    Right b -> b && outStr /= "error"

    chAllR' <- liftIO $ (unsafeCoerce chAllR :: IO [Either SomeException Bool])
    let chAllR'' = rights chAllR'

    return $ v'' && and chAllR''

runCheck' :: String -> String -> [String] -> State t -> [Expr] -> Expr -> Ghc (HValue, [HValue])
runCheck' modN entry chAll s@(State {type_env = te}) ars out = do
    let Left (v, _) = findFunc (T.pack entry) [Just $ T.pack modN] (expr_env s)
    let e = mkApp $ Var v:ars
    let g2Gen = H.toList $ H.filter (\x -> adt_source x == ADTG2Generated) te 
    let pg = updatePrettyGuide (exprNames e)
           . updatePrettyGuide (exprNames out)
           . updatePrettyGuide g2Gen
           $ mkPrettyGuide $ varIds v
    let arsStr = T.unpack $ printHaskellPG pg s e
    let outStr = T.unpack $ printHaskellPG pg s out

    let arsType = T.unpack $ mkTypeHaskellPG pg (typeOf e)
        outType = T.unpack $ mkTypeHaskellPG pg (typeOf out) 
        -- trace("type of out " ++ show (typeOf out) ++ "\n" ++ "out " ++ show out) 
    -- Pass g2 generated type into the environment 
    let (_, g2str) = mapAccumL g2GeneratedTypeToName (pg,s) g2Gen
    dyn <- getSessionDynFlags
    let dyn' = xopt_set dyn MagicHash
    setSessionDynFlags dyn'

    _ <- mapM runDecls $ trace (intercalate "\n" (map (\s -> ("g2Gen constructors " ++ s)) g2str )) g2str

    let chck = case outStr == "error" of
                    False -> "try (evaluate (" ++ arsStr ++ " == " ++ "("
                                    ++ outStr ++ " :: " ++ outType ++ ")" ++ ")) :: IO (Either SomeException Bool)"
                    True -> "try (evaluate ( (" ++ arsStr ++ " :: " ++ arsType ++
                                                    ") == " ++ arsStr ++ ")) :: IO (Either SomeException Bool)"
    v' <- compileExpr chck
    
    let chArgs = ars ++ [out] 
    let chAllStr = map (\f -> T.unpack $ printHaskellPG pg s $ mkApp ((simpVar $ T.pack f):chArgs)) chAll
    let chAllStr' = map (\str -> "try (evaluate (" ++ str ++ ")) :: IO (Either SomeException Bool)") chAllStr

    chAllR <- mapM compileExpr chAllStr'

    return $ (v', chAllR)

loadToCheck :: [FilePath] -> [FilePath] -> String -> [GeneralFlag] -> Ghc ()
loadToCheck proj src modN gflags = do
        _ <- loadProj Nothing proj src gflags simplTranslationConfig

        let primN = mkModuleName "GHC.Prim"
        let primImD = simpleImportDecl primN

        let prN = mkModuleName "Prelude"
        let prImD = simpleImportDecl prN

        let exN = mkModuleName "Control.Exception"
        let exImD = simpleImportDecl exN

        let coerceN = mkModuleName "Data.Coerce"
        let coerceImD = simpleImportDecl coerceN

        let charN = mkModuleName "Data.Char"
        let charD = simpleImportDecl charN

        let mdN = mkModuleName modN
        let imD = simpleImportDecl mdN

        setContext [IIDecl primImD, IIDecl prImD, IIDecl exImD, IIDecl coerceImD, IIDecl imD, IIDecl charD]

simpVar :: T.Text -> Expr
simpVar s = Var (Id (Name s Nothing 0 Nothing) TyBottom)

runHPC :: FilePath -> String -> String -> [(State t, Bindings, [Expr], Expr, Maybe FuncCall)] -> IO ()
runHPC src modN entry in_out = do
    let calls = map (\(s, _, i, o, _) -> toCall entry s i o) in_out

    runHPC' src modN calls

-- Compile with GHC, and check that the output we got is correct for the input
runHPC' :: FilePath -> String -> [String] -> IO ()
runHPC' src modN ars = do
    srcCode <- readFile src
    let srcCode' = removeModule modN srcCode

    let spces = "  "

    let chck = intercalate ("\n" ++ spces) $ map (\s -> "print (" ++ s ++ ")") ars

    let mainFunc = "\n\nmain :: IO ()\nmain =do\n" ++ spces ++ chck ++ "\n" ++ spces

    let mainN = "Main_" ++ modN

    writeFile (mainN ++ ".hs") (srcCode' ++ mainFunc)

    callProcess "ghc" ["-fhpc", mainN ++ ".hs"]
    callProcess ("./" ++ mainN) []

    callProcess "hpc" ["report", mainN]

    -- putStrLn mainFunc

toCall :: String -> State t -> [Expr] -> Expr -> String
toCall entry s ars _ = T.unpack . printHaskell s $ mkApp ((simpVar $ T.pack entry):ars)

removeModule :: String -> String -> String
removeModule modN s =
    let
        r = mkRegex $ "module " ++ modN ++ " where"
    in
    subRegex r s ""
