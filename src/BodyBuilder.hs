--  File     : BodyBuilder.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Fri 22 May 2015 10:59:56 AEST
--  Purpose  : A monad to build up a procedure Body, with copy propagation
--  Copyright: (c) 2015 Peter Schachte.  All rights reserved.
--

module BodyBuilder (
  BodyBuilder, buildBody, freshVarName, instr, buildFork, completeFork,
  beginBranch, endBranch, definiteVariableValue
  ) where

import AST
import Snippets
import Util
import Options (LogSelection(BodyBuilder))
import Data.Map as Map
import Data.List as List
import Data.Set as Set
import Data.Maybe
import Data.Bits
import Control.Applicative
import Control.Monad
import Control.Monad.Extra (whenJust)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.State


----------------------------------------------------------------
--                       The BodyBuilder Monad
--
-- This monad is used to build up a ProcBody one instruction at a time.
--
-- buildBody runs the monad, producing a ProcBody.
-- instr adds a single instruction to then end of the procBody being built.
-- Forks are produced by the following functions:
--    buildFork     initiates a fork on a specified variable
--    beginBranch   starts a new branch of the current fork
--    endBranch     ends the current branch
--    completeFork  completes the current fork
--
-- A ProcBody is considered to have a unique continuation if it either
-- does not end in a branch, or if all but at most one of the branches
-- it ends with ends with a definite failure (a PrimTest (ArgInt 0 _)).
-- 
-- No instructions can be added between buildFork and beginBranch, or
-- between endBranch and beginBranch, or if the current state does not have
-- a unique continuation. A new fork can be built within a branch, but must
-- be completed before the branch is ended.
--
-- The ProcBody type does not support having anything follow a fork. Once a
-- ProcBody forks, the branches do not join again. Instead, each branch of
-- a fork should end with a call to another proc, which does whatever
-- should come after the fork. To handle this, once a fork is completed,
-- the BodyBuilder starts a new Unforked instruction sequence, and records
-- the completed fork as the predecessor of the Unforked sequence. This
-- also permits a fork to follow the Unforked sequence which follows a
-- fork. When producing the final ProcBody, if the current Unforked
-- sequence is short (or empty) and there is a predecessor fork, we simply
-- add the sequence to the end of each of branch of the fork and remove the
-- Unforked sequence. If it is not short and there is a predecessor, we
-- create a fresh proc whose input arguments are all the live variables,
-- whose outputs are the current proc's outputs, and whose body is built
-- from Unforked sequence, add a call to this fresh proc to each branch of
-- the previous Forked sequence, and remove the Unforked.
--
-- We handle a Forked sequence by generating a ProcBody for each branch,
-- collecting these as the branches of a ProcBody, and taking the
-- instructions from the preceding Unforked as the instruction sequence of
-- the ProcBody.
--
-- Note that for convenience/efficiency, we collect the instructions in a
-- sequence and the branches in a fork in reverse order, so these are
-- reversed when converting to a ProcBody.
--
-- Some transformation is performed by the BodyBuilder monad; in
-- particular, we keep track of variable=variable assignments, and replace
-- references to the destination (left) variable with the source (right)
-- variable.  This usually leaves the assignment dead, to be removed in
-- a later pass.  We also keep track of previous instructions, and later
-- calls to the same instructions with the same inputs are replaced by
-- assignments to the outputs with the old outputs.  We also handle some
-- arithmetic equivalences, entailments, and tautologies (eg, on a branch
-- where we know x==y, a call to x<=y will always return true; for
-- unsigned x, x<0 is always false, and x>0 is replaced with x!=0).
-- We also maintain a counter for temporary variable names.
--
-- The BodyState has two constructors:  Unforked is used before the first
-- fork, and after each new branch is created. Instructions can just be
-- added to this. Forked is used after a new fork is begun and before its
-- first branch is created, between ending a branch and starting a new one,
-- and after the fork is completed. New instructions can be added and new
-- forks built only when in the Unforked state. In the Forked state, we can
-- only create a new branch.
--
-- These constructors are used in a zipper-like structure, where the top of the
-- structure is the part we're building, and below that is the parent, ie,
-- the fork structure of which it's a part. This is implemented as follows:
--
--     buildFork is called when the state is Unforked.  It creates a new
--     Forked state, with the old state as its origin and an empty list
--     of bodies.  The new parent is the same as the old one.
--
--     beginBranch is called when the state is Forked.  It creates a new
--     Unforked state with the old state as parent.
--
--     endBranch is called with either a Forked or Unforked state.  It
--     adds the current state to the parent state's list of bodies and
--     makes that the new state.
--
--     completeFork is called when the state is Forked.  It doesn't
--     change the state.
----------------------------------------------------------------

type BodyBuilder = StateT BodyState Compiler

-- Holds the content of a ProcBody while we're building it.
data BodyState = BodyState {
      currBuild   :: [Placed Prim],   -- ^The body we're building, reversed
      currSubst   :: Substitution,    -- ^variable substitutions to propagate
      blockDefs   :: Set PrimVarName, -- ^All variables defined in this block
      outSubst    :: VarSubstitution, -- ^Substitutions for var assignments
      subExprs    :: ComputedCalls,   -- ^Previously computed calls to reuse
      -- XXX I don't think definers is actually used; get rid of it?
      definers    :: VarDefiner,      -- ^The call that defined each var
      failed      :: Bool,            -- ^True if this body always fails
      tmpCount    :: Int,             -- ^The next temp variable number to use
      buildState  :: BuildState,      -- ^What state this node is in
      parent      :: Maybe BodyState  -- ^What comes before/above this
      } deriving (Eq,Show)


data BuildState
    = Unforked           -- ^Still building; ready for more instrs
    | Forked {           -- ^Building a new fork
        forkingVar    :: PrimVarName,  -- ^Variable that selects branch to take
        forkingVarTy  :: TypeSpec,     -- ^Type of stForkVar
        knownVal   :: Maybe Integer,   -- ^Definite value of stForkVar if known
        bodies     :: [BodyState],     -- ^BodyStates of all branches so far
        complete   :: Bool             -- ^Whether the fork has been completed
        } deriving (Eq,Show)


-- | A fresh BodyState with specified temp counter and output var substitution
initState :: Int -> VarSubstitution -> BodyState
initState tmp oSubst =
    BodyState [] Map.empty Set.empty oSubst Map.empty Map.empty False
              tmp Unforked Nothing


-- | A BodyState as a new child of the specified BodyState
childState :: BodyState -> BuildState -> BodyState
childState st@BodyState{currSubst=iSubst,outSubst=oSubst,subExprs=subs,
                        definers=defs,tmpCount=tmp} bld =
    BodyState [] iSubst Set.empty oSubst subs defs False tmp bld $ Just st


logState :: BodyBuilder ()
logState = do
    st <- get
    logBuild $ "     Current state:" ++ fst (showState 8 st)
    return ()


showState :: Int -> BodyState -> (String,Int)
showState indent BodyState{parent=par, currBuild=revPrims, buildState=bld,
                           blockDefs=defed} =
    let (str  ,indent')   = maybe ("",indent) (showState indent) par
        str'              = showPlacedPrims indent' (reverse revPrims)
        sets              = "\n" ++ replicate indent ' '
                            ++ "# retargetable assignments: {"
                            ++ intercalate ", " (List.map show $
                                                 Set.toList defed)
                            ++ "}"
        (str'',indent'') = showBuildState indent' bld
    in  (str ++ str' ++ sets ++ str'', indent'')


showBuildState :: Int -> BuildState -> (String,Int)
showBuildState indent Unforked = ("", indent)
showBuildState indent (Forked var ty val bodies False) =
    let intro = showSwitch indent var ty val
        indent' = indent + 4
        content = showBranches indent' 0 True $ reverse bodies
    in  (intro++content,indent')
showBuildState indent (Forked var ty val bodies True) =
    let intro = showSwitch indent var ty val
        indent' = indent + 4
        content = showBranches indent' 0 False $ reverse bodies
    in  (intro++content,indent)


showBranches :: Int -> Int -> Bool -> [BodyState] -> String
showBranches indent bodyNum True [] = showCase indent bodyNum
showBranches indent bodyNum False [] = ""
showBranches indent bodyNum open (body:bodies) =
    showCase indent bodyNum
    ++ fst (showState (indent+4) body)
    ++ showBranches indent (bodyNum+1) open bodies


showCase indent bodyNum = "\n" ++ replicate indent ' ' ++ show bodyNum ++ "::"

showSwitch indent var ty val =
    "\n"
    ++ replicate indent ' ' ++ "case " ++ show var ++ ":" ++ show ty
    ++ maybe "" (\v-> " (=" ++ show v ++ ")") val
    ++ " of"


type Substitution = Map PrimVarName PrimArg
type VarSubstitution = Map PrimVarName PrimVarName


-- To handle common subexpression elimination, we keep a map from previous
-- calls with their outputs removed to the outputs.  This type encapsulates
-- that.  In the Prim keys, all PrimArgs are inputs.
type ComputedCalls = Map Prim [PrimArg]


-- To handle branch conditions, we keep track of the statement that bound
-- each variable.  For each arm of a branch, this lets us work out what
-- must be true and what must be false for that arm, so we can avoid
-- redundant tests.
type VarDefiner = Map PrimVarName Prim


-- |Allocate the next temp variable name and ensure it's not allocated again
freshVarName :: BodyBuilder PrimVarName
freshVarName = do
    tmp <- gets tmpCount
    modify (\st -> st {tmpCount = tmp + 1})
    return $ PrimVarName (mkTempName tmp) 0



----------------------------------------------------------------
--                      BodyBuilder Primitive Operations
----------------------------------------------------------------

-- |Run a BodyBuilder monad and extract the final proc body
buildBody :: Int -> VarSubstitution -> BodyBuilder a
          -> Compiler (Int,Set PrimVarName,ProcBody)
buildBody tmp oSubst builder = do
    logMsg BodyBuilder "<<<< Beginning to build a proc body"
    st <- execStateT builder $ initState tmp oSubst
    logMsg BodyBuilder ">>>> Finished building a proc body"
    logMsg BodyBuilder "     Current state:"
    logMsg BodyBuilder $ fst $ showState 8 st
    currBody (ProcBody [] NoFork) st


-- |Start a new fork on var of type ty
buildFork :: PrimVarName -> TypeSpec -> BodyBuilder ()
buildFork var ty = do
    st <- get
    var' <- expandVar var boolType
    logBuild $ "<<<< beginning to build a new fork on " ++ show var
               ++ " (-> " ++ show var' ++ ")"
    case buildState st of
      Forked{complete=True} ->
        shouldnt "Building a fork in Forked state"
      Forked{complete=False} ->
        shouldnt "Building a fork in Forking state"
      Unforked -> do
        arg' <- expandVar var ty
        logBuild $ "     (expands to " ++ show arg' ++ ")"
        let (fvar,fval) =
              case arg' of
                  ArgInt n _ -> -- result known at compile-time
                    (var,Just n)
                  ArgVar var' varType _ _ _ -> -- statically unknown result
                    (var',Nothing)
                  _ -> shouldnt "switch on non-integer variable"
        put $ childState st $  Forked fvar ty fval [] False
        logState


-- |Complete a fork previously initiated by buildFork.
completeFork :: BodyBuilder ()
completeFork = do
    st <- get
    case buildState st of
      Forked{complete=True} ->
        shouldnt "Completing an already-completed fork"
      Unforked ->
        shouldnt "Completing an un-built fork"
      Forked var ty val bods False -> do
        logBuild $ ">>>> ending fork on " ++ show var
        -- Prepare for any instructions coming after the fork
        let parent = st {buildState = Forked var ty val bods True,
                         tmpCount = maximum $ tmpCount <$> bods}
        put $ childState parent Unforked
        logState


-- |Start a new branch for the next integer value of the switch variable.
beginBranch :: BodyBuilder ()
beginBranch = do
    st <- get
    case buildState st of
      Forked{complete=True} ->
        shouldnt "Beginning a branch in an already-completed fork"
      Unforked ->
        shouldnt "Beginning a branch in an un-built fork"
      Forked var ty val bods False -> do
        let branchNum = fromIntegral $ length bods
        logBuild $ "<<<< <<<< Beginning to build branch "
                   ++ show branchNum ++ " on " ++ show var
        put $ childState st Unforked
        -- XXX Do we want to maintain this field?
        -- let failed' = failed st || maybe False (/=branchNum) val
        -- XXX also add consequences of this, eg if var is result of X==Y
        --     comparison and var == 1, then record that X==Y.
        when (isNothing val) $ addSubst var $ ArgInt branchNum intType
        logState


-- |End the current branch.
endBranch :: BodyBuilder ()
endBranch = do
    (par,st,var,ty,val,bodies) <- gets popParent
    logBuild $ ">>>> >>>> Ending branch "
              ++ show (length bodies) ++ " on " ++ show var
    put $ par { buildState=Forked var ty val (st:bodies) False }
    logState


-- |Return the closest Forking ancestor of a state, and fix its immediate
--  child to no longer list it as parent
popParent :: BodyState -> (BodyState,BodyState,PrimVarName,TypeSpec,
                           Maybe Integer,[BodyState])
popParent st@BodyState{parent=Nothing} =
    shouldnt "endBranch with no open branch to end"
popParent st@BodyState{parent=(Just
             par@BodyState{buildState=(Forked var ty val branches False)})} =
    (par, st {parent = Nothing}, var, ty, val, branches)
popParent st@BodyState{parent=Just par} =
    let (ancestor, fixedPar, var, ty, val, branches) = popParent par
    in  (ancestor,st {parent=Just fixedPar}, var, ty, val, branches)


-- |Return Just the known value of the specified variable, or Nothing
definiteVariableValue :: PrimVarName -> BodyBuilder (Maybe PrimArg)
definiteVariableValue var = do
    arg <- expandVar var AnyType
    case arg of
        ArgVar{} -> return Nothing -- variable (unknown) result
        _ -> return $ Just arg

buildPrims :: BodyState -> BodyBuilder a -> Compiler (a,BodyState)
buildPrims st builder = runStateT builder st


-- -- |Augment st with whatever consequences can be deduced from the fact
-- --  that prim assigned var the value val.
-- propagateBinding :: PrimVarName -> TypeSpec -> Int -> Prim -> BodyBuilder ()
-- propagateBinding var ty val (PrimForeign "llvm" "icmp" [cmp] [a1, a2, _]) = do
--     propagateComparison var ty val cmp a1 a2
-- propagateBinding _ _ _ _ = return ()


-- -- |Augment st with whatever consequences can be deduced from the fact
-- --  that the specified LLVM comparison assigned var the value val.
-- propagateComparison :: PrimVarName -> TypeSpec -> Int -> String
--                     -> PrimArg -> PrimArg -> BodyBuilder ()
-- propagateComparison var ty val cmp a1 a2 = do
--     -- note that the negation of the test gives the negation of the result
--     let (oppositeCmp,trues0,falses0) = comparisonRelatives cmp
--     let (_,trues,falses) = if val == 0
--                            then comparisonRelatives oppositeCmp
--                            else ("", trues0, falses0)
--     let allConsequences = (oppositeCmp,1-val)
--                           :  zip trues (repeat 1)
--                           ++ zip falses (repeat 0)
--     logBuild $ "Adding consequences of branch:  "
--                ++ show (List.map (\(c,v) ->
--                                   PrimForeign "llvm" "icmp" [c]
--                                   [a1, a2, ArgInt (fromIntegral v) ty])
--                         allConsequences)
--     let insertInstr (c,v)
--             = Map.insert
--               (PrimForeign "llvm" "icmp" [c] [canonicaliseArg a1,
--                                               canonicaliseArg a2])
--               [ArgInt (fromIntegral v) ty]
--     modify (\s -> s {subExprs = List.foldr insertInstr (subExprs s)
--                                 allConsequences
--                     })
--     mp <- gets subExprs
--     logBuild $ "After adding consequences, subExprs = " ++ show mp


-- -- |Given an LLVM comparison instruction name, returns a triple of
-- --  (1) the negation of the comparison
-- --  (2) a list of comparisons that are true whenever it is true
-- --  (3) a list of comparisons that are false whenever it is true, other than
-- --      the negation (1)
-- comparisonRelatives :: String -> (String,[String],[String])
-- comparisonRelatives "eq"  = ("ne", ["sle", "sge", "ule", "uge"],
--                           ["slt", "sgt", "ult", "ugt"])
-- comparisonRelatives "ne"  = ("eq", [], [])
-- comparisonRelatives "slt" = ("sge", ["sle", "ne"], [])
-- comparisonRelatives "sge" = ("slt", [], [])
-- comparisonRelatives "sgt" = ("sle", ["sge", "ne"], [])
-- comparisonRelatives "sle" = ("sgt", [], [])
-- comparisonRelatives "ult" = ("uge", ["ule", "ne"], [])
-- comparisonRelatives "uge" = ("ult", [], [])
-- comparisonRelatives "ugt" = ("ule", ["uge", "ne"], [])
-- comparisonRelatives "ule" = ("ugt", [], [])
-- comparisonRelatives comp = shouldnt $ "unknown llvm comparison " ++ comp



-- |Add an instruction to the current body, after applying the current
--  substitution. If it's a move instruction, add it to the current
--  substitution.
instr :: Prim -> OptPos -> BodyBuilder ()
instr prim pos = do
    st <- get
    case st of
      BodyState{failed=True}  -> do -- ignore if we've already failed
        logBuild $ "  Failing branch:  ignoring instruction " ++ show prim
        return ()
      BodyState{failed=False,buildState=Unforked} -> do
        prim' <- argExpandedPrim prim
        logBuild $ "Generating instr " ++ show prim ++ " -> " ++ show prim'
        instr' prim' pos
      _ ->
        shouldnt "instr in Forked context"


instr' :: Prim -> OptPos -> BodyBuilder ()
instr' prim@(PrimForeign "llvm" "move" []
           [val, argvar@(ArgVar var _ flow _ _)]) pos
  = do
    logBuild $ "  Expanding move(" ++ show val ++ ", " ++ show argvar ++ ")"
    unless (flow == FlowOut && argFlowDirection val == FlowIn) $ 
      shouldnt "move instruction with wrong flow"
    outVar <- gets (Map.findWithDefault var var . outSubst)
    addSubst outVar val
    rawInstr prim pos
    recordVarSet argvar
-- XXX this is a bit of a hack to work around not threading a heap
--     through the code, which causes the compiler to try to reuse
--     the results of calls to alloc.  Since the mutate primitives
--     already have an output value, that should stop us from trying
--     to reuse modified structures or the results of calls to
--     access after a structure is modified, so alloc should be
--     the only problem that needs fixing.  We don't want to fix this
--     by threading a heap through, because it's fine to reorder calls
--     to alloc.
instr' prim@(PrimForeign "lpvm" "alloc" [] [_,argvar]) pos = do
    logBuild $ "  Leaving alloc alone"
    rawInstr prim pos
    recordVarSet argvar
instr' prim@(PrimTest (ArgInt 0 _)) pos = do
    rawInstr prim pos
    logBuild $ "  Found fail instruction; noting failing branch"
    -- note guaranteed failure
    modify (\s -> s { failed=True })
instr' prim pos = do
    let (prim',newOuts) = splitPrimOutputs prim
    logBuild $ "Looking for computed instr " ++ show prim' ++ " ..."
    currSubExprs <- gets subExprs
    logBuild $ "  with subExprs = " ++ show currSubExprs
    match <- gets (Map.lookup prim' . subExprs)
    case match of
        Nothing -> do
            -- record prim executed (and other modes), and generate instr
            logBuild "not found"
            recordEntailedPrims prim
            rawInstr prim pos
            mapM_ recordVarSet $ primOutputs prim
        Just oldOuts -> do
            -- common subexpr: just need to record substitutions
            logBuild $ "found it; substituting "
                       ++ show oldOuts ++ " for " ++ show newOuts
            mapM_ (\(newOut,oldOut) ->
                     instr' (PrimForeign "llvm" "move" []
                              [mkInput oldOut, newOut])
                     Nothing)
                  $ zip newOuts oldOuts


-- | Invert an output arg to be an input arg.
mkInput :: PrimArg -> PrimArg
mkInput (ArgVar name ty _ ftype lst) = ArgVar name ty FlowIn Ordinary False
mkInput arg@ArgInt{} = arg
mkInput arg@ArgFloat{} = arg
mkInput arg@ArgString{} = arg
mkInput arg@ArgChar{} = arg


argExpandedPrim :: Prim -> BodyBuilder Prim
argExpandedPrim (PrimCall pspec args) = do
    args' <- mapM expandArg args
    return $ PrimCall pspec args'
argExpandedPrim (PrimForeign lang nm flags args) = do
    args' <- mapM expandArg args
    return $ simplifyForeign lang nm flags args'
argExpandedPrim (PrimTest arg) = do
    arg' <- expandArg arg
    return $ PrimTest arg'


-- |Construct a fake version of a Prim instruction containing only its
-- inputs, and with inessential parts canonicalised away.  Also return the
-- outputs of the instruction.
splitPrimOutputs :: Prim -> (Prim, [PrimArg])
splitPrimOutputs prim =
    let (inArgs,outArgs) = splitArgsByMode $ primArgs prim
    in  (replacePrimArgs prim $ canonicaliseArg <$> inArgs, outArgs)


-- |Returns a list of all output arguments of the input Prim
primOutputs :: Prim -> [PrimArg]
primOutputs prim =
    List.filter ((==FlowOut) . argFlowDirection) $ primArgs prim


-- |Add a binding for a variable. If that variable is an output for the
--  proc being defined, also add an explicit assignment to that variable.
addSubst :: PrimVarName -> PrimArg -> BodyBuilder ()
addSubst var val = do
    logBuild $ "      adding subst " ++ show var ++ " -> " ++ show val
    modify (\s -> s { currSubst = Map.insert var val $ currSubst s })
    subst <- gets currSubst
    logBuild $ "      new subst = " ++ show subst


-- |Reconrd that the specified arg (which must be a variable) has been set.
recordVarSet :: PrimArg -> BodyBuilder ()
recordVarSet (ArgVar nm _ FlowOut _ _) =
    modify (\s -> s { blockDefs = Set.insert nm $ blockDefs s })
recordVarSet arg =
    shouldnt $ "recordVarSet of non-output argument " ++ show arg

-- |Record all instructions equivalent to the input prim in the lookup table,
--  so if we later see an equivalent instruction we don't repeat it but
--  reuse the already-computed outputs.  This implements common subexpression
--  elimination.  It can also handle optimisations like recognizing the
--  reconstruction of a deconstructed value, and accounts for commutative
--  operations and inverse operations.
recordEntailedPrims :: Prim -> BodyBuilder ()
recordEntailedPrims prim = do
    let pair1 = splitPrimOutputs prim
    instrPairs <- (pair1:) <$> lift (instrInverses prim)
    logBuild $ "Recording computed instrs"
               ++ List.concatMap
                  (\(p,o)-> "\n        " ++ show p ++ " -> " ++ show o)
                  instrPairs
    modify (\s -> s {subExprs = List.foldr (uncurry Map.insert) (subExprs s)
                                instrPairs,
                     definers = List.foldr
                                (flip Map.insert prim . argVarName)
                                (definers s) $ snd pair1})


-- |Return a list of instructions that have been effectively already been
--  computed, mostly because they are inverses of instructions already
--  computed, or because of commutativity.
--  XXX Doesn't yet handle multiple modes for PrimCalls
instrInverses :: Prim -> Compiler [(Prim,[PrimArg])]
instrInverses prim =
   List.map (\(p,os) -> (canonicalisePrim p, os)) <$> instrInverses' prim

instrInverses' :: Prim -> Compiler [(Prim,[PrimArg])]
instrInverses' (PrimForeign "lpvm" "cast" flags [a1,a2]) =
    return [(PrimForeign "lpvm" "cast" flags [a2], [a1])]
instrInverses' (PrimForeign "llvm" "add" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "sub" flags [a3,a2], [a1]),
            (PrimForeign "llvm" "sub" flags [a3,a1], [a2]),
            (PrimForeign "llvm" "add" flags [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "sub" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "add" flags [a3,a2], [a1]),
            (PrimForeign "llvm" "add" flags [a2,a3], [a1]),
            (PrimForeign "llvm" "sub" flags [a1,a3], [a2])]
instrInverses' (PrimForeign "llvm" "mul" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "mul" flags [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "fadd" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "fadd" flags [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "fmul" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "fmul" flags [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "and" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "and" flags [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "or" flags [a1,a2,a3]) =
    return [(PrimForeign "llvm" "or" flags [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["eq"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["eq"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["ne"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["ne"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["slt"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["sgt"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["sgt"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["slt"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["ult"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["ugt"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["ugt"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["ult"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["sle"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["sge"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["sge"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["sle"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["ule"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["uge"] [a2,a1], [a3])]
instrInverses' (PrimForeign "llvm" "icmp" ["uge"] [a1,a2,a3]) =
    return [(PrimForeign "llvm" "icmp" ["ule"] [a2,a1], [a3])]
instrInverses' _ = return []



-- |Unconditionally add an instr to the current body
rawInstr :: Prim -> OptPos -> BodyBuilder ()
rawInstr prim pos = do
    logBuild $ "---- adding instruction " ++ show prim
    validateInstr prim
    modify $ addInstrToState (maybePlace prim pos)



splitArgsByMode :: [PrimArg] -> ([PrimArg], [PrimArg])
splitArgsByMode args =
    List.partition ((==FlowIn) . argFlowDirection) args


canonicalisePrim :: Prim -> Prim
canonicalisePrim (PrimCall nm args) =
    PrimCall nm $ List.map (canonicaliseArg . mkInput) args
canonicalisePrim (PrimForeign lang op flags args) =
    PrimForeign lang op flags $ List.map (canonicaliseArg . mkInput) args
canonicalisePrim (PrimTest arg) =
    PrimTest $ (canonicaliseArg . mkInput) arg


-- |Standardise unimportant info in an arg, so that it is equal to any
--  other arg with the same content.
canonicaliseArg :: PrimArg -> PrimArg
canonicaliseArg (ArgVar nm _ fl _ _) = ArgVar nm AnyType fl Ordinary False
canonicaliseArg (ArgInt v _)         = ArgInt v AnyType
canonicaliseArg (ArgFloat v _)       = ArgFloat v AnyType
canonicaliseArg (ArgString v _)      = ArgString v AnyType
canonicaliseArg (ArgChar v _)        = ArgChar v AnyType


validateInstr :: Prim -> BodyBuilder ()
validateInstr i@(PrimCall _ args)        = mapM_ (validateArg i) args
validateInstr i@(PrimForeign _ _ _ args) = mapM_ (validateArg i) args
validateInstr (PrimTest _)               = return ()

validateArg :: Prim -> PrimArg -> BodyBuilder ()
validateArg instr (ArgVar _ ty _ _ _) = validateType ty instr
validateArg instr (ArgInt    _ ty)    = validateType ty instr
validateArg instr (ArgFloat  _ ty)    = validateType ty instr
validateArg instr (ArgString _ ty)    = validateType ty instr
validateArg instr (ArgChar   _ ty)    = validateType ty instr

validateType :: TypeSpec -> Prim -> BodyBuilder ()
validateType InvalidType instr =
    shouldnt $ "InvalidType in argument of " ++ show instr
-- XXX AnyType is now a valid type treated as a word type
-- validateType AnyType instr =
--     shouldnt $ "AnyType in argument of " ++ show instr
validateType _ instr = return ()


addInstrToState :: Placed Prim -> BodyState -> BodyState
addInstrToState ins st@BodyState{buildState=Unforked} =
    st { currBuild = ins:currBuild st}
addInstrToState ins st@BodyState{buildState=bld@Forked{complete=False,bodies=bods}} =
    st { buildState = bld {bodies=List.map (addInstrToState ins) bods} }
addInstrToState ins st@BodyState{buildState=bld@Forked{complete=True,bodies=bods}} =
    st { buildState = bld {bodies=List.map (addInstrToState ins) bods} }


-- |Return the current ultimate value of the specified variable name and type
expandVar :: PrimVarName -> TypeSpec -> BodyBuilder PrimArg
expandVar var ty = expandArg $ ArgVar var ty FlowIn Ordinary False


-- |Return the current ultimate value of the input argument.
expandArg :: PrimArg -> BodyBuilder PrimArg
expandArg arg@(ArgVar var _ FlowIn _ _) = do
    var' <- gets (Map.lookup var . currSubst)
    logBuild $ "Expanded " ++ show var ++ " to variable " ++ show var'
    maybe (return arg) expandArg var'
expandArg (ArgVar var typ FlowOut ftype lst) = do
    var' <- gets (Map.findWithDefault var var . outSubst)
    return $ ArgVar var' typ FlowOut ftype lst
expandArg arg = return arg



----------------------------------------------------------------
--                              Constant Folding
----------------------------------------------------------------

-- |Transform primitives with all inputs known into a move instruction by
--  performing the operation at compile-time.
simplifyForeign ::  String -> ProcName -> [Ident] -> [PrimArg] -> Prim
simplifyForeign "llvm" op flags args = simplifyOp op flags args
simplifyForeign lang op flags args = PrimForeign lang op flags args


-- | Simplify and canonicalise llvm instructions where possible. This
--   handles constant folding and simple (single-operation) algebraic
--   simplifications (left and right identities and annihilators).
--   Commutative ops are canonicalised by putting the smaller argument
--   first, but only for integer ops.  Integer inequalities are
--   canonicalised by putting smaller argument first and flipping
--   comparison if necessary.
simplifyOp :: ProcName -> [Ident] -> [PrimArg] -> Prim
-- Integer ops
simplifyOp "add" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1+n2) ty) output
simplifyOp "add" _ [ArgInt 0 ty, arg, output] =
  primMove arg output
simplifyOp "add" _ [arg, ArgInt 0 ty, output] =
  primMove arg output
simplifyOp "add" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "add" flags [arg2, arg1, output]
simplifyOp "sub" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1-n2) ty) output
simplifyOp "sub" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "mul" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1*n2) ty) output
simplifyOp "mul" _ [ArgInt 1 ty, arg, output] =
  primMove arg output
simplifyOp "mul" _ [arg, ArgInt 1 ty, output] =
  primMove arg output
simplifyOp "mul" _ [ArgInt 0 ty, _, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "mul" _ [_, ArgInt 0 ty, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "mul" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "mul" flags [arg2, arg1, output]
simplifyOp "div" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1 `div` n2) ty) output
simplifyOp "div" _ [arg, ArgInt 1 _, output] =
  primMove arg output
-- Bitstring ops
simplifyOp "and" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 .&. fromIntegral n2) ty) output
simplifyOp "and" _ [ArgInt 0 ty, _, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "and" _ [_, ArgInt 0 ty, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "and" _ [ArgInt (-1) _, arg, output] =
  primMove arg output
simplifyOp "and" _ [arg, ArgInt (-1) _, output] =
  primMove arg output
simplifyOp "and" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "and" flags [arg2, arg1, output]
simplifyOp "or" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 .|. fromIntegral n2) ty) output
simplifyOp "or" _ [ArgInt (-1) ty, _, output] =
  primMove (ArgInt (-1) ty) output
simplifyOp "or" _ [_, ArgInt (-1) ty, output] =
  primMove (ArgInt (-1) ty) output
simplifyOp "or" _ [ArgInt 0 _, arg, output] =
  primMove arg output
simplifyOp "or" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "or" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "or" flags [arg2, arg1, output]
simplifyOp "xor" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 `xor` fromIntegral n2) ty) output
simplifyOp "xor" _ [ArgInt 0 _, arg, output] =
  primMove arg output
simplifyOp "xor" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "xor" flags [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "xor" flags [arg2, arg1, output]
-- XXX should probably put shift ops here, too
-- Integer comparisons, including special handling of unsigned comparison to 0
simplifyOp "icmp" ["eq"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1==n2) output
simplifyOp "icmp" ["eq"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["eq"] [arg2, arg1, output]
simplifyOp "icmp" ["ne"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1/=n2) output
simplifyOp "icmp" ["ne"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["ne"] [arg2, arg1, output]
simplifyOp "icmp" ["slt"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1<n2) output
simplifyOp "icmp" ["slt"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["sgt"] [arg2, arg1, output]
simplifyOp "icmp" ["sle"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1<=n2) output
simplifyOp "icmp" ["sle"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["sge"] [arg2, arg1, output]
simplifyOp "icmp" ["sgt"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1>n2) output
simplifyOp "icmp" ["sgt"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["slt"] [arg2, arg1, output]
simplifyOp "icmp" ["sge"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1>=n2) output
simplifyOp "icmp" ["sge"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["sle"] [arg2, arg1, output]
simplifyOp "icmp" ["ult"] [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'<n2') output
simplifyOp "icmp" ["ult"] [_, ArgInt 0 _, output] = -- nothing is < 0
  primMove (ArgInt 0 boolType) output
simplifyOp "icmp" ["ult"] [a1, ArgInt 1 ty, output] = -- only 0 is < 1
  PrimForeign "llvm" "icmp" ["eq"] [a1,ArgInt 0 ty,output]
simplifyOp "icmp" ["ult"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["ugt"] [arg2, arg1, output]
simplifyOp "icmp" ["ule"] [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'<=n2') output
simplifyOp "icmp" ["ule"] [ArgInt 0 _, _, output] = -- 0 is <= everything
  primMove (ArgInt 1 boolType) output
simplifyOp "icmp" ["ule"] [ArgInt 1 ty, a2, output] = -- 1 is <= all but 0
  PrimForeign "llvm" "icmp" ["ne"] [ArgInt 0 ty,a2,output]
simplifyOp "icmp" ["ule"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["uge"] [arg2, arg1, output]
simplifyOp "icmp" ["ugt"] [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'>n2') output
simplifyOp "icmp" ["ugt"] [ArgInt 0 _, _, output] = -- 0 is > nothing
  primMove (ArgInt 0 boolType) output
simplifyOp "icmp" ["ugt"] [ArgInt 1 ty, a2, output] = -- 1 is > only 0
  PrimForeign "llvm" "icmp" ["eq"] [ArgInt 0 ty,a2,output]
simplifyOp "icmp" ["ugt"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["ult"] [arg2, arg1, output]
simplifyOp "icmp" ["uge"] [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'>=n2') output
simplifyOp "icmp" ["uge"] [_, ArgInt 0 _, output] = -- everything is >= 0
  primMove (ArgInt 1 boolType) output
simplifyOp "icmp" ["uge"] [a1, ArgInt 1 ty, output] = -- all but 0 is >= 1
  PrimForeign "llvm" "icmp" ["ne"] [a1,ArgInt 0 ty,output]
simplifyOp "icmp" ["uge"] [arg1, arg2, output]
    | arg2 < arg1 = PrimForeign "llvm" "icmp" ["ule"] [arg2, arg1, output]
-- Float ops
simplifyOp "fadd" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1+n2) ty) output
simplifyOp "fadd" _ [ArgFloat 0 _, arg, output] =
  primMove arg output
simplifyOp "fadd" _ [arg, ArgFloat 0 _, output] =
  primMove arg output
simplifyOp "fsub" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1-n2) ty) output
simplifyOp "fsub" _ [arg, ArgFloat 0 _, output] =
  primMove arg output
simplifyOp "fmul" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1*n2) ty) output
simplifyOp "fmul" _ [arg, ArgFloat 1 _, output] =
  primMove arg output
simplifyOp "fmul" _ [ArgFloat 1 _, arg, output] =
  primMove arg output
-- We don't handle float * 0.0 because of the semantics of IEEE floating mult.
simplifyOp "fdiv" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1/n2) ty) output
simplifyOp "fdiv" _ [arg, ArgFloat 1 _, output] =
  primMove arg output
-- Float comparisons
simplifyOp "fcmp" ["eq"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1==n2) output
simplifyOp "fcmp" ["ne"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1/=n2) output
simplifyOp "fcmp" ["slt"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1<n2) output
simplifyOp "fcmp" ["sle"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1<=n2) output
simplifyOp "fcmp" ["sgt"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1>n2) output
simplifyOp "fcmp" ["sge"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1>=n2) output
simplifyOp name flags args = PrimForeign "llvm" name flags args


boolConstant :: Bool -> PrimArg
boolConstant bool = ArgInt (fromIntegral $ fromEnum bool) boolType

----------------------------------------------------------------
--                  Reassembling the ProcBody
--
-- Once we've built up a BodyState, this code assembles it into a new ProcBody.
-- While we're at it, we also mark the last use of each variable, eliminate
-- calls that don't produce any output needed later in the body, and eliminate
-- any move instructions that moves a variable defined in the same block as the
-- move and not used after the move.  Most other move instructions were removed
-- while building BodyState, but that approach cannot eliminate moves to output
-- parameters.
----------------------------------------------------------------

currBody :: ProcBody -> BodyState -> Compiler (Int,Set PrimVarName,ProcBody)
currBody body st = do
    st' <- execStateT (rebuildBody st)
           $ BkwdBuilderState (Map.keysSet $ outSubst st) Map.empty 0 body
    return (asmTmpCount st', asmUsedLater st', asmFollowing st')


type BkwdBuilder = StateT BkwdBuilderState Compiler

-- |BkwdBuilderState is used to store context info while building a ProcBody
-- backwards from a BodyState, itself the result of rebuilding a ProcBody
-- forwards.  Because construction runs backwards, the state mostly holds
-- information about the following code.
data BkwdBuilderState = BkwdBuilderState {
      asmUsedLater :: Set PrimVarName,  -- ^Variables used later in computation
      asmRenaming  :: VarSubstitution,  -- ^Variable substitution to apply
      asmTmpCount  :: Int,              -- ^Highest temporary variable number
      asmFollowing :: ProcBody          -- ^Code to come later
      } deriving (Eq,Show)



rebuildBody :: BodyState -> BkwdBuilder ()
rebuildBody st@BodyState{currBuild=prims, currSubst=subst, blockDefs=defs,
                         buildState=bldst, parent=par} = do
    bkwdSt <- get
    logBkwd $ "Rebuilding body:" ++ fst (showState 8 st)
              ++ "\nwith currSubst = " ++ show subst
              ++ "\n and followed by:" ++ showBlock 8 (asmFollowing bkwdSt)
    let usedLater = asmUsedLater bkwdSt
    let following = asmFollowing bkwdSt
    let (usedLater',following') = pruneBody subst usedLater following
    modify (\s -> s { asmFollowing = following', asmUsedLater = usedLater' })
    case bldst of
      Unforked -> nop
      Forked{complete=False} ->
        shouldnt "Building proc body for bodystate with incomplete fork"
      Forked var ty fixedval bods True ->
        case fixedval of
          Just val ->
            rebuildBody $ selectFork val bods
          Nothing -> do
            -- XXX Perhaps we should generate a new proc for the parent par in
            -- cases where it's more than a few prims.  Currently UnBranch
            -- ensures that's not needed, but maybe it shouldn't.
            sts <- mapM (rebuildBranch subst) $ reverse bods
            let usedLater'' = List.foldr Set.union usedLater'
                              $ asmUsedLater <$> sts
            logBkwd $ "Switch on " ++ show var
                      ++ " with usedLater " ++ show usedLater''
            let lastUse = Set.notMember var usedLater''
            let usedLater''' = Set.insert var usedLater''
            let tmp = maximum $ List.map asmTmpCount sts
            let followingBranches = List.map asmFollowing sts
            put $ BkwdBuilderState usedLater''' Map.empty tmp
                  $ ProcBody [] $ PrimFork var ty lastUse followingBranches
    mapM_ (placedApply (bkwdBuildStmt defs)) prims
    maybe nop rebuildBody par


-- |Select the element of bods specified by num
selectFork :: Integral a => a -> [b] -> b
selectFork num bods =
    if num' >= 0 && num' < length bods
    then bods !! num'
    else shouldnt $ "Out-of-bounds fixed value in fork " ++ show num'
  where num' = fromIntegral num


rebuildBranch :: Substitution -> BodyState -> BkwdBuilder BkwdBuilderState
rebuildBranch subst bod = do
    bkwdSt <- get
    lift $ execStateT (rebuildBody bod) bkwdSt


-- |Prune the specified ProcBody according to the variable bindings of
-- subst, eliminating any forks whose selection is forced by the bindings.
-- XXX This is weak.  First, it should prune forks recursively, and second,
-- the returned used var set should only included the bodies that are not
-- pruned.  But to do that, ProcBody needs to track used variables, or else
-- we have to recompute it from scratch.
pruneBody :: Substitution -> Set PrimVarName -> ProcBody
          -> (Set PrimVarName,ProcBody)
pruneBody subst used body@ProcBody{bodyPrims=prims,
                                   bodyFork=PrimFork{forkVar=var,
                                                     forkBodies=bods}} =
    case Map.lookup var subst of
      Just (ArgInt num _) ->
        let bod = selectFork num bods
        in  (Set.delete var used, bod { bodyPrims = prims ++ bodyPrims bod })
      _ -> (used,body)
pruneBody _ used body = (used,body)



bkwdBuildStmt :: Set PrimVarName -> Prim -> OptPos -> BkwdBuilder ()
bkwdBuildStmt defs prim pos = do
    usedLater <- gets asmUsedLater
    let args = primArgs prim
    args' <- mapM renameArg args
    case (prim,args') of
      (PrimForeign "llvm" "move" [] _, [ArgVar{argVarName=fromVar},
                                        ArgVar{argVarName=toVar}])
        | Set.notMember fromVar usedLater && Set.member fromVar defs ->
            modify (\s -> s { asmRenaming = Map.insert fromVar toVar
                                            $ asmRenaming s })
      _ -> do
        let (ins, outs) = splitArgsByMode args'
        when (any (`Set.member` usedLater) $ argVarName <$> outs) $ do
          let prim' = replacePrimArgs prim $ markIfLastUse usedLater <$> args'
          let inVars = argVarName <$> List.filter argIsVar ins
          let usedLater' = List.foldr Set.insert usedLater inVars
          st@BkwdBuilderState{asmFollowing=bd@ProcBody{bodyPrims=prims}} <- get
          put $ st { asmFollowing =
                       bd { bodyPrims = maybePlace prim' pos:prims },
                     asmUsedLater = usedLater' }


renameArg :: PrimArg -> BkwdBuilder PrimArg
renameArg arg@ArgVar{argVarName=name} = do
    name' <- gets (Map.findWithDefault name name . asmRenaming)
    return $ arg { argVarName = name' }
renameArg arg = return arg


markIfLastUse :: Set PrimVarName -> PrimArg -> PrimArg
markIfLastUse usedLater arg@ArgVar{argVarName=nm,argVarFlow=FlowIn}
  | Set.notMember nm usedLater = arg {argVarFinal=True}
markIfLastUse _ arg = arg


----------------------------------------------------------------
--                                  Logging
----------------------------------------------------------------

-- |Log a message, if we are logging body building activity.
logBuild :: String -> BodyBuilder ()
logBuild s = lift $ logMsg BodyBuilder s


-- |Log a message, if we are logging body building activity.
logBkwd :: String -> BkwdBuilder ()
logBkwd s = lift $ logMsg BodyBuilder s