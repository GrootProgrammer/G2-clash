module G2.Internals.Liquid.TCValues where

import G2.Internals.Language.Syntax

data TCValues = TCValues { lhTC :: Name
                         , lhEq :: Name
                         , lhNe :: Name }
