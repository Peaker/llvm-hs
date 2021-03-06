{-# LANGUAGE
  TemplateHaskell,
  MultiParamTypeClasses,
  RecordWildCards,
  UndecidableInstances,
  OverloadedStrings
  #-}
module LLVM.Internal.Target where

import LLVM.Prelude

import Control.Monad.AnyCont
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Trans.Except

import Data.Attoparsec.ByteString
import Data.Attoparsec.ByteString.Char8
import qualified Data.ByteString as ByteString
import Data.Char
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Foreign.C.String
import Foreign.Ptr

import LLVM.Internal.Coding
import LLVM.Internal.String ()
import LLVM.Internal.LibraryFunction
import LLVM.DataLayout
import LLVM.Exception

import LLVM.AST.DataLayout

import qualified LLVM.Internal.FFI.LLVMCTypes as FFI
import qualified LLVM.Internal.FFI.Target as FFI

import qualified LLVM.Relocation as Reloc
import qualified LLVM.Target.Options as TO
import qualified LLVM.CodeModel as CodeModel
import qualified LLVM.CodeGenOpt as CodeGenOpt

genCodingInstance [t| Reloc.Model |] ''FFI.RelocModel [
  (FFI.relocModelDefault, Reloc.Default),
  (FFI.relocModelStatic, Reloc.Static),
  (FFI.relocModelPIC, Reloc.PIC),
  (FFI.relocModelDynamicNoPic, Reloc.DynamicNoPIC)
 ]

genCodingInstance [t| CodeModel.Model |] ''FFI.CodeModel [
  (FFI.codeModelDefault,CodeModel.Default),
  (FFI.codeModelJITDefault, CodeModel.JITDefault),
  (FFI.codeModelSmall, CodeModel.Small),
  (FFI.codeModelKernel, CodeModel.Kernel),
  (FFI.codeModelMedium, CodeModel.Medium),
  (FFI.codeModelLarge, CodeModel.Large)
 ]

genCodingInstance [t| CodeGenOpt.Level |] ''FFI.CodeGenOptLevel [
  (FFI.codeGenOptLevelNone, CodeGenOpt.None),
  (FFI.codeGenOptLevelLess, CodeGenOpt.Less),
  (FFI.codeGenOptLevelDefault, CodeGenOpt.Default),
  (FFI.codeGenOptLevelAggressive, CodeGenOpt.Aggressive)
 ]

genCodingInstance [t| TO.FloatABI |] ''FFI.FloatABIType [
  (FFI.floatABIDefault, TO.FloatABIDefault),
  (FFI.floatABISoft, TO.FloatABISoft),
  (FFI.floatABIHard, TO.FloatABIHard)
 ]

genCodingInstance [t| TO.FloatingPointOperationFusionMode |] ''FFI.FPOpFusionMode [
  (FFI.fpOpFusionModeFast, TO.FloatingPointOperationFusionFast),
  (FFI.fpOpFusionModeStandard, TO.FloatingPointOperationFusionStandard),
  (FFI.fpOpFusionModeStrict, TO.FloatingPointOperationFusionStrict)
 ]

-- | <http://llvm.org/doxygen/classllvm_1_1Target.html>
newtype Target = Target (Ptr FFI.Target)

-- | e.g. an instruction set extension
newtype CPUFeature = CPUFeature ByteString
  deriving (Eq, Ord, Read, Show)

instance EncodeM e ByteString es => EncodeM e (Map CPUFeature Bool) es where
  encodeM = encodeM . ByteString.intercalate "," . map (\(CPUFeature f, enabled) -> (if enabled then "+" else "-") <> f) . Map.toList

instance (Monad d, DecodeM d ByteString es) => DecodeM d (Map CPUFeature Bool) es where
  decodeM es = do
    s <- decodeM es
    let flag = do
          en <- choice [char8 '-' >> return False, char8 '+' >> return True]
          s <- ByteString.pack <$> many1 (notWord8 (fromIntegral (ord ',')))
          return (CPUFeature s, en)
        features = liftM Map.fromList (flag `sepBy` (char8 ','))
    case parseOnly (do f <- features; endOfInput; return f) s of
      Right features -> return features
      Left _ -> fail "failure to parse CPUFeature string"
                       
-- | Find a 'Target' given an architecture and/or a \"triple\".
-- | <http://llvm.org/doxygen/structllvm_1_1TargetRegistry.html#a3105b45e546c9cc3cf78d0f2ec18ad89>
-- | Be sure to run either 'initializeAllTargets' or
-- 'initializeNativeTarget' before expecting this to succeed,
-- depending on what target(s) you want to use. May throw
-- 'LookupTargetException' if no target is found.
lookupTarget ::
  Maybe ShortByteString -- ^ arch
  -> ShortByteString -- ^ \"triple\" - e.g. x86_64-unknown-linux-gnu
  -> IO (Target, ShortByteString)
lookupTarget arch triple = flip runAnyContT return $ do
  cErrorP <- alloca
  cNewTripleP <- alloca
  arch <- encodeM (maybe "" id arch)
  triple <- encodeM triple
  target <- liftIO $ FFI.lookupTarget arch triple cNewTripleP cErrorP
  when (target == nullPtr) $ throwM . LookupTargetException =<< decodeM cErrorP
  liftM (Target target, ) $ decodeM cNewTripleP

-- | <http://llvm.org/doxygen/classllvm_1_1TargetOptions.html>
newtype TargetOptions = TargetOptions (Ptr FFI.TargetOptions)

-- | bracket creation and destruction of a 'TargetOptions' object
withTargetOptions :: (TargetOptions -> IO a) -> IO a
withTargetOptions = bracket FFI.createTargetOptions FFI.disposeTargetOptions . (. TargetOptions)

-- | set all target options
pokeTargetOptions :: TO.Options -> TargetOptions -> IO ()
pokeTargetOptions hOpts (TargetOptions cOpts) = do
  mapM_ (\(c, ha) -> FFI.setTargetOptionFlag cOpts c =<< encodeM (ha hOpts)) [
    (FFI.targetOptionFlagPrintMachineCode, TO.printMachineCode),
    (FFI.targetOptionFlagLessPreciseFPMADOption, TO.lessPreciseFloatingPointMultiplyAddOption),
    (FFI.targetOptionFlagUnsafeFPMath, TO.unsafeFloatingPointMath),
    (FFI.targetOptionFlagNoInfsFPMath, TO.noInfinitiesFloatingPointMath),
    (FFI.targetOptionFlagNoNaNsFPMath, TO.noNaNsFloatingPointMath),
    (FFI.targetOptionFlagHonorSignDependentRoundingFPMathOption, TO.honorSignDependentRoundingFloatingPointMathOption),
    (FFI.targetOptionFlagNoZerosInBSS, TO.noZerosInBSS),
    (FFI.targetOptionFlagGuaranteedTailCallOpt, TO.guaranteedTailCallOptimization),
    (FFI.targetOptionFlagEnableFastISel, TO.enableFastInstructionSelection),
    (FFI.targetOptionFlagUseInitArray, TO.useInitArray),
    (FFI.targetOptionFlagDisableIntegratedAS, TO.disableIntegratedAssembler),
    (FFI.targetOptionFlagCompressDebugSections, TO.compressDebugSections),
    (FFI.targetOptionFlagTrapUnreachable, TO.trapUnreachable)
   ]
  FFI.setStackAlignmentOverride cOpts =<< encodeM (TO.stackAlignmentOverride hOpts)
  FFI.setFloatABIType cOpts =<< encodeM (TO.floatABIType hOpts)
  FFI.setAllowFPOpFusion cOpts =<< encodeM (TO.allowFloatingPointOperationFusion hOpts)

-- | get all target options
peekTargetOptions :: TargetOptions -> IO TO.Options
peekTargetOptions (TargetOptions tOpts) = do
  let gof = decodeM <=< FFI.getTargetOptionsFlag tOpts
  printMachineCode
    <- gof FFI.targetOptionFlagPrintMachineCode
  lessPreciseFloatingPointMultiplyAddOption
    <- gof FFI.targetOptionFlagLessPreciseFPMADOption
  unsafeFloatingPointMath
    <- gof FFI.targetOptionFlagUnsafeFPMath
  noInfinitiesFloatingPointMath
    <- gof FFI.targetOptionFlagNoInfsFPMath
  noNaNsFloatingPointMath
    <- gof FFI.targetOptionFlagNoNaNsFPMath
  honorSignDependentRoundingFloatingPointMathOption
    <- gof FFI.targetOptionFlagHonorSignDependentRoundingFPMathOption
  noZerosInBSS
    <- gof FFI.targetOptionFlagNoZerosInBSS
  guaranteedTailCallOptimization
    <- gof FFI.targetOptionFlagGuaranteedTailCallOpt
  enableFastInstructionSelection
    <- gof FFI.targetOptionFlagEnableFastISel
  useInitArray
    <- gof FFI.targetOptionFlagUseInitArray
  disableIntegratedAssembler
    <- gof FFI.targetOptionFlagDisableIntegratedAS
  compressDebugSections
    <- gof FFI.targetOptionFlagCompressDebugSections
  trapUnreachable
    <- gof FFI.targetOptionFlagTrapUnreachable
  stackAlignmentOverride <- decodeM =<< FFI.getStackAlignmentOverride tOpts
  floatABIType <- decodeM =<< FFI.getFloatABIType tOpts
  allowFloatingPointOperationFusion <- decodeM =<< FFI.getAllowFPOpFusion tOpts
  return TO.Options { .. }

-- | <http://llvm.org/doxygen/classllvm_1_1TargetMachine.html>
newtype TargetMachine = TargetMachine (Ptr FFI.TargetMachine)

-- | bracket creation and destruction of a 'TargetMachine'
withTargetMachine ::
    Target
    -> ShortByteString -- ^ triple
    -> ByteString -- ^ cpu
    -> Map CPUFeature Bool -- ^ features
    -> TargetOptions
    -> Reloc.Model
    -> CodeModel.Model
    -> CodeGenOpt.Level
    -> (TargetMachine -> IO a)
    -> IO a
withTargetMachine
  (Target target)
  triple
  cpu
  features
  (TargetOptions targetOptions)
  relocModel
  codeModel
  codeGenOptLevel = runAnyContT $ do
  triple <- encodeM triple
  cpu <- encodeM cpu
  features <- encodeM features
  relocModel <- encodeM relocModel
  codeModel <- encodeM codeModel
  codeGenOptLevel <- encodeM codeGenOptLevel
  anyContToM $ bracket (
      FFI.createTargetMachine
         target
         triple
         cpu
         features
         targetOptions
         relocModel
         codeModel
         codeGenOptLevel
      )
      FFI.disposeTargetMachine
      . (. TargetMachine)

-- | <http://llvm.org/doxygen/classllvm_1_1TargetLowering.html>
newtype TargetLowering = TargetLowering (Ptr FFI.TargetLowering)

-- | get the 'TargetLowering' of a 'TargetMachine'
getTargetLowering :: TargetMachine -> IO TargetLowering
getTargetLowering (TargetMachine tm) = TargetLowering <$> error "FIXME: getTargetLowering" -- FFI.getTargetLowering tm

-- | Initialize the native target. This function is called automatically in these Haskell bindings
-- when creating an 'LLVM.ExecutionEngine.ExecutionEngine' which will require it, and so it should
-- not be necessary to call it separately.
initializeNativeTarget :: IO ()
initializeNativeTarget = do
  failure <- decodeM =<< liftIO FFI.initializeNativeTarget
  when failure $ fail "native target initialization failed"

-- | the target triple corresponding to the target machine
getTargetMachineTriple :: TargetMachine -> IO ShortByteString
getTargetMachineTriple (TargetMachine m) = decodeM =<< FFI.getTargetMachineTriple m

-- | the default target triple that LLVM has been configured to produce code for
getDefaultTargetTriple :: IO ShortByteString
getDefaultTargetTriple = decodeM =<< FFI.getDefaultTargetTriple

-- | a target triple suitable for loading code into the current process
getProcessTargetTriple :: IO ShortByteString
getProcessTargetTriple = decodeM =<< FFI.getProcessTargetTriple

-- | the LLVM name for the host CPU
getHostCPUName :: IO ByteString
getHostCPUName = decodeM FFI.getHostCPUName

-- | a space-separated list of LLVM feature names supported by the host CPU
getHostCPUFeatures :: IO (Map CPUFeature Bool)
getHostCPUFeatures =
  decodeM =<< FFI.getHostCPUFeatures

-- | 'DataLayout' to use for the given 'TargetMachine'
getTargetMachineDataLayout :: TargetMachine -> IO DataLayout
getTargetMachineDataLayout (TargetMachine m) = do
  dlString <- decodeM =<< FFI.getTargetMachineDataLayout m
  let Right (Just dl) = runExcept . parseDataLayout BigEndian $ dlString
  return dl

-- | Initialize all targets so they can be found by 'lookupTarget'
initializeAllTargets :: IO ()
initializeAllTargets = FFI.initializeAllTargets

-- | Bracket creation and destruction of a 'TargetMachine' configured for the host
withHostTargetMachine :: (TargetMachine -> IO a) -> IO a
withHostTargetMachine f = do
  initializeAllTargets
  triple <- getProcessTargetTriple
  cpu <- getHostCPUName
  features <- getHostCPUFeatures
  (target, _) <- lookupTarget Nothing triple
  withTargetOptions $ \options ->
    withTargetMachine target triple cpu features options Reloc.Default CodeModel.Default CodeGenOpt.Default f

-- | <http://llvm.org/docs/doxygen/html/classllvm_1_1TargetLibraryInfo.html>
newtype TargetLibraryInfo = TargetLibraryInfo (Ptr FFI.TargetLibraryInfo)

-- | Look up a 'LibraryFunction' by its standard name
getLibraryFunction :: TargetLibraryInfo -> ShortByteString -> IO (Maybe LibraryFunction)
getLibraryFunction (TargetLibraryInfo f) name = flip runAnyContT return $ do
  libFuncP <- alloca :: AnyContT IO (Ptr FFI.LibFunc)
  name <- (encodeM name :: AnyContT IO CString)
  r <- decodeM =<< (liftIO $ FFI.getLibFunc f name libFuncP)
  forM (if r then Just libFuncP else Nothing) $ decodeM <=< peek

-- | Get a the current name to be emitted for a 'LibraryFunction'
getLibraryFunctionName :: TargetLibraryInfo -> LibraryFunction -> IO ShortByteString
getLibraryFunctionName (TargetLibraryInfo f) l = flip runAnyContT return $ do
  l <- encodeM l
  decodeM $ FFI.libFuncGetName f l

-- | Set the name of the function on the target platform that corresponds to funcName
setLibraryFunctionAvailableWithName ::
  TargetLibraryInfo
  -> LibraryFunction
  -> ShortByteString -- ^ The function name to be emitted
  -> IO ()
setLibraryFunctionAvailableWithName (TargetLibraryInfo f) libraryFunction name = flip runAnyContT return $ do
  name <- encodeM name
  libraryFunction <- encodeM libraryFunction
  liftIO $ FFI.libFuncSetAvailableWithName f libraryFunction name

-- | look up information about the library functions available on a given platform
withTargetLibraryInfo ::
  ShortByteString -- ^ triple
  -> (TargetLibraryInfo -> IO a)
  -> IO a
withTargetLibraryInfo triple f = flip runAnyContT return $ do
  triple <- encodeM triple
  liftIO $ bracket (FFI.createTargetLibraryInfo triple) FFI.disposeTargetLibraryInfo (f . TargetLibraryInfo)
