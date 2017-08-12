-- | Language
--   Provides the language definition of G2. Should not be confused with Core
--   Haskell, although design imitates Core Haskell closely.
module G2.Internals.Language.Syntax
    ( module G2.Internals.Language.Syntax
    ) where

-- | The native GHC defintion states that a `Program` is a list of `Binds`.
type Program = [Binds]

-- | Typically `Binds` are categorized as recursive or non-recursive. This is
-- because recursive let bindings require their local scopes of all bindings
-- to contain each other. Technically, all bindings can be expressed as
-- recursive, though GHC differentiates them. We do not care here because we
-- assume naming independence.
type Binds = [(Id, Expr)]

-- | The occurrence name is defined as a string, with a `Maybe` module name
-- appearing. The `Int` denotes a `Unique` translated from GHC. For instance,
-- in the case of @Map.empty@, the occurrence name is @"empty"@, while the
-- module name is some variant of @Just \"Data.Map\"@.
data Name = Name String (Maybe String) Int deriving (Show, Eq, Read, Ord)

data Id = Id Name Type deriving (Show, Eq, Read)

-- | Expressions are defined as:
--   * Variables
--   * Literals such as unwrapped Int# types
--   * Primitive known operation on WRAPPED types such as +, <, etc
--   * Data Constructors
--   * Application of expressions: apply RHS to LHS, LHS being a function
--   * Lambda expressions where the `Id` is the lambda binder
--   * Let bindings such that `Binds` appears in the scope for the body `Expr`
--   * Case pattern matching where `Expr` is inspection, `Id` is binding
--   * Type expression wrappers for who knows what
data Expr = Var Id
          | Lit Lit
          | Prim Primitive
          | Data DataCon
          | App Expr Expr
          | Lam Id Expr
          | Let Binds Expr
          | Case Expr Id [Alt]
          | Type Type
          deriving (Show, Eq, Read)

-- | These enumerate a set of known, and G2-augmented operations, over wrapped
-- data types such as Int, Char, Double, etc. We refer to these as primitives.
-- We further introduce a assertion and assumption as special features.
data Primitive = Ge | Gt | Eq | Lt | Le
               | And | Or | Not | Implies
               | Plus | Minus | Mult | Div
               | Assert | Assume
               deriving (Show, Eq, Read)

-- | Literals for denoting unwrapped types such as Int#, Double#. These would
-- be contained within primitives.
data Lit = LitInt Int
         | LitFloat Rational
         | LitDouble Rational
         | LitChar Char
         | LitString String
         | LitBool Bool
         deriving (Show, Eq, Read)

-- | These are used for expressing wrapped data type constructors such as I#.
-- In the context of these documentations, primitive types refers to the boxed
-- types `Int`, `Double`, `Float`, `Char`, and `Bool`.
data PrimCon = I | D | F | C | B deriving (Show, Eq, Read)

-- | Data constructor. We have a special ditinction for primitive types.
data DataCon = DataCon Name Type [Type]
             | PrimCon PrimCon
             deriving (Show, Eq, Read)

-- | Alternative case constructors, which are done by structural matching,
-- which is a phrase I invented to describe this :)
data AltCon = DataAlt DataCon
            | LitAlt Lit
            | Default
            deriving (Show, Eq, Read)

-- | Alternatives consist of the consturctor that is used to structurally match
-- onto them, a list of parameters corresponding to this constructor, which
-- serve to perform binding in the environment scope. The `Expr` is what is
-- evaluated provided that the `AltCon` successfully matches.
data Alt = Alt AltCon [Id] Expr deriving (Show, Eq, Read)

-- | TyBinder is used only inthe `TyForAll`. It has other uses if we wish to
-- make the `TyCon` more verbose.
data TyBinder = AnonTyBndr
              | NamedTyBndr Name
              deriving (Show, Eq, Read)

-- | Types are decomposed as follows:
-- * Type variables correspond to the aliasing of a type
-- * TyInt, TyFloat, etc, denote primitive types
-- * TyLitInt, TyLitFloat etc denote unwrapped primitive types.
-- * Function type. For instance (assume Int): \x -> x + 1 :: TyFun TyInt TyInt
-- * Application, often reducible: (TyApp (TyFun TyInt TyInt) TyInt) :: TyInt
-- * Type constructor (see below) application creates an actual type
-- * For all types
-- * BOTTOM
data Type = TyVar Name Type
          | TyInt | TyFloat | TyDouble | TyChar | TyString | TyBool
          | TyLitInt | TyLitFloat | TyLitDouble | TyLitChar | TyLitString
          | TyFun Type Type
          | TyApp Type Type
          | TyConApp TyCon [Type]
          | TyForAll TyBinder Type
          | TyBottom
          deriving (Show, Eq, Read)

-- | We keep type constructors simple. Semantically, type constructors are not
-- types, they are literally constructors used to make types. Types are
-- entities with kind *, while constructors have kind * -> *, * -> * -> * and
-- so on. Type constructors can be thought of as data constructors, where
-- instead of putting in data values to make a solid piece of data object, you
-- put in types instead.
data TyCon = TyCon Name deriving (Show, Eq, Read)

