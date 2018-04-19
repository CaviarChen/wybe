--  File     : BinaryFactory.hs
--  RCS      : $Id$
--  Author   : Ashutosh Rishi Ranjan
--  Origin   : Thu Mar 26 14:25:37 AEDT 2015
--  Purpose  : Deriving AST Types to be Binary instances
--  Copyright: (c) 2015 Peter Schachte.  All rights reserved.
module BinaryFactory
       where

import           AST
import           Control.Monad
import           Crypto.Hash
import           Data.Binary as B
-- import qualified Data.ByteString.Char8 as BL
import qualified Data.ByteString.Lazy as BL
import qualified LLVM.AST as LLVMAST
import           Text.Parsec.Pos
                 ( SourcePos, sourceName, sourceLine,
                   sourceColumn, newPos )
import           Config (magicVersion)
import qualified Data.List as List


-- * Self Deriving instances
instance Binary Visibility
instance Binary Determinism
instance Binary t => Binary (Placed t)
instance Binary ArgFlowType
instance Binary ResourceSpec
instance Binary FlowDirection
instance Binary PrimFlow
instance Binary TypeSpec
instance Binary Exp
instance Binary Stmt
instance Binary ParamInfo
instance Binary Prim
instance Binary PrimVarName
instance Binary PrimArg

-- Procedures
instance Binary ProcSpec
instance Binary ProcImpln
instance Binary PrimProto
instance Binary PrimParam
instance Binary ProcBody
instance Binary PrimFork
instance Binary SuperprocSpec
instance Binary ProcDef
instance Binary ProcProto
instance Binary Param
instance Binary ResourceFlowSpec
-- Module implementation
instance Binary ModuleImplementation
instance Binary ResourceImpln
instance Binary TypeDef
instance Binary ImportSpec
-- Module
instance Binary Module
instance Binary ModuleInterface


instance Binary Item
instance Binary FnProto
instance Binary TypeProto
instance Binary TypeImpln
-- * Manual Serialisation

instance Binary EncodedLPVM


instance Binary SourcePos where
  put pos = do put $ sourceName pos
               put $ sourceLine pos
               put $ sourceColumn pos

  get = liftM3 newPos get get get


instance Binary LLVMAST.Definition where
  put = put . show
  get = do def <- get
           return (read def :: LLVMAST.Definition)

instance Binary LLVMAST.Module where
  put = put . show
  get = do def <- get
           return (read def :: LLVMAST.Module)



-- * Encoding


-- | A Module is encoding by creating an 'EncodedLPVM' type which wraps the
-- Module `m` and all its sub-modules. This type is serialised and prefixed
-- with 4 magic bytes.
encodeModule :: Module -> Compiler BL.ByteString
encodeModule m = do
    let msg = "Unable to get loaded Module for binary encoding."
    -- func to get get a trusted loaded Module from it's spec
    let getm name = trustFromJustM msg $ getLoadedModule name
    subModSpecs <- collectSubModules (modSpec m)
    subMods <- mapM getm subModSpecs
    let encoded = B.encode $ makeEncodedLPVM (m:subMods)
    return $ BL.append (BL.pack magicVersion) encoded



-- * Decoding


decodeModule :: [ModSpec] -> BL.ByteString -> Compiler [Module]
decodeModule required bs = do
    let (magic, rest) = BL.splitAt 4 bs
    if magic == BL.pack magicVersion
        then
        case B.decodeOrFail rest of
            Left _ -> do
                Warning <!> "Error decoding LPVM bytes."
                return []
            Right (_, _, lpvm) -> decodeEncodedLPVM required lpvm
        else do
        Warning <!> "Extracted LPVM version mismatch."
        return []


decodeEncodedLPVM ::  [ModSpec] -> EncodedLPVM -> Compiler [Module]
decodeEncodedLPVM required (EncodedLPVM _ ms) =
    if List.all (`elem` specs) required
    then return ms
    else return []
  where
    specs = List.map modSpec ms


-- * Hashing functions

sha1 :: BL.ByteString -> Digest SHA1
sha1 = hashlazy

hashItems :: [Item] -> String
hashItems = show . sha1 . encode
