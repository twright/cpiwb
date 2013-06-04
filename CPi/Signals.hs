-- (C) Copyright Chris Banks 2011-2013

-- This file is part of The Continuous Pi-calculus Workbench (CPiWB). 

--     CPiWB is free software: you can redistribute it and/or modify
--     it under the terms of the GNU General Public License as published by
--     the Free Software Foundation, either version 3 of the License, or
--     (at your option) any later version.

--     CPiWB is distributed in the hope that it will be useful,
--     but WITHOUT ANY WARRANTY; without even the implied warranty of
--     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--     GNU General Public License for more details.

--     You should have received a copy of the GNU General Public License
--     along with CPiWB.  If not, see <http://www.gnu.org/licenses/>.

module CPi.Signals 
    (modelCheckSig,
     Signal,
     SignalSet
    )where

import CPi.Lib 
import qualified CPi.ODE as ODE
-- import CPi.Semantics
import CPi.Logic

import Data.Map (Map)
-- import qualified Data.Map as Map
import qualified Control.Exception as X
-- import qualified Control.Monad.Trans.State as S


-------------------------------------
-- Signal Monitoring for LBC and CPi
-------------------------------------

-- | Signal for a formula is a covering list of intervals, each with truth value.
type Signal = [((Double,Double),Bool)]
type SignalSet = Map Formula Signal

-- | Model checking using the Signal Monitoring technique
modelCheckSig :: Env                   -- ^ Environment
              -> ODE.Solver            -- ^ ODE solver function
              -> (Maybe Trace)         -- ^ Pre-computed time series (or Nothing)
              -> Process               -- ^ Process to execute
              -> (Int,(Double,Double)) -- ^ Time points: (points,(t0,tn))
              -> Formula               -- ^ Formula to check
              -> Bool
modelCheckSig env solver (Just trace) p (res,tms) f
    = snd . head $ minCover $ sig env p solver trace f
modelCheckSig env solver Nothing p (res,tms) f
    = snd . head $ minCover $ sig env p solver (solve env solver (res,tms) p) f
--FIXME: unchecked use of head
--TODO:  optimise: memoize sigs, overusing minCover?

-- calculate the signal for an LBC formula
sig :: Env -> Process -> ODE.Solver -> Trace -> Formula -> Signal
sig _ _ _ tr T = [(traceInterval tr,True)]
sig _ _ _ tr F = [(traceInterval tr,False)]
sig _ _ _ tr (ValGT v1 v2) 
    = minCover $ sigTrav tr (\t-> getVal t v1 > getVal t v2)
sig _ _ _ tr (ValGE v1 v2) 
    = minCover $ sigTrav tr (\t-> getVal t v1 >= getVal t v2)
sig _ _ _ tr (ValLT v1 v2) 
    = minCover $ sigTrav tr (\t-> getVal t v1 < getVal t v2)
sig _ _ _ tr (ValLE v1 v2) 
    = minCover $ sigTrav tr (\t-> getVal t v1 <= getVal t v2)
sig _ _ _ tr (ValEq v1 v2) 
    = minCover $ sigTrav tr (\t-> getVal t v1 == getVal t v2)
sig _ _ _ tr (ValNEq v1 v2) 
    = minCover $ sigTrav tr (\t-> getVal t v1 /= getVal t v2)
sig env p solver tr (Conj f1 f2) 
    = conjSig (sig env p solver tr f1) (sig env p solver tr f2)
sig env p solver tr (Disj f1 f2) 
    = disjSig (sig env p solver tr f1) (sig env p solver tr f2)
sig env p solver tr (Impl f1 f2) 
    = sig env p solver tr (Disj f2 (Neg f1))
sig env p solver tr (Neg f) 
    = negSig (sig env p solver tr f)
sig env p solver tr (Until i f1 f2) 
    = untilSig i (sig env p solver tr f1) (sig env p solver tr f2)
sig env p solver tr (Rels i f1 f2) 
    = sig env p solver tr (Neg (Until i (Neg f1) (Neg f2)))
sig env p solver tr (Nec i f) 
    = sig env p solver tr (Neg (Pos i (Neg f)))
sig env p solver tr (Pos i f) 
    = shiftSig i (sig env p solver tr f)
sig env p solver tr (Gtee q f) 
    = gteeSig env p solver tr (maybe (bad q) id (lookupProcName env q)) f
      where bad q = X.throw $ CpiException $
                    "Process \""++q++"\" not in the Environment."

sigTrav :: Trace -> (Trace -> Bool) -> Signal 
sigTrav [] _ = []
sigTrav tr f = ((traceStart tr, traceStart(traceNext tr)), (f tr)) 
               : sigTrav (traceNext tr) f

-- The minimal covering of a signal
minCover :: Signal -> Signal
minCover [] = []
minCover [i] = [i]
minCover (i1:i2:is)
    | (snd i1 == snd i2) 
        = minCover $ ((fst(fst i1), snd(fst i2)), snd i1) : is
    | otherwise 
        = i1 : minCover (i2:is)

-- The negation of a signal
negSig :: Signal -> Signal
negSig [] = []
negSig ((i,v):sig) = (i,not v) : negSig sig

-- The minimal common (uniform) covering of signals:
-- mccl gives the left signal w.r.t. the right
mccl :: Signal -> Signal -> Signal
mccl (((l1,u1),v1):sig1) (((l2,u2),v2):sig2)
    | u1 < u2
        = ((l1,u1),v1) : mccl sig1 (((l2,u2),v2):sig2)
    | u1 > u2
        = ((l1,u2),v1) : mccl (((u2,u1),v1):sig1) sig2
    | otherwise
        = ((l1,u1),v1) : mccl sig1 sig2
mccl [] (s:sig) = X.throw $ CpiException 
                  "CPi.Signals.mccl requires signals of same cover"
mccl (s:sig) [] = X.throw $ CpiException
                  "CPi.Signals.mccl requires signals of same cover"
mccl [] [] = []
-- and mccr gives the right signal w.r.t. the left
mccr :: Signal -> Signal -> Signal
mccr (((l1,u1),v1):sig1) (((l2,u2),v2):sig2)
    | u1 < u2
        = ((l2,u1),v2) : mccr sig1 (((u1,u2),v2):sig2)
    | u1 > u2
        = ((l2,u2),v2) : mccr (((u2,u1),v1):sig1) sig2
    | otherwise
        = ((l2,u2),v2) : mccr sig1 sig2
mccr [] (s:sig) = X.throw $ CpiException
                  "CPi.Signals.mccr requires signals of same cover"
mccr (s:sig) [] = X.throw $ CpiException
                  "CPi.Signals.mccr requires signals of same cover"
mccr [] [] = []

-- Test if two signals have uniform covering
uniform :: Signal -> Signal -> Bool
uniform ((i,_):s) ((j,_):t)
    | i==j      = uniform s t
    | otherwise = False
uniform ((i,_):s) [] = False
uniform [] ((i,_):s) = False
uniform [] [] = True

-- The conjunction of two signals
conjSig :: Signal -> Signal -> Signal
conjSig sig1 sig2 = minCover $ conjSig' (mccl sig1 sig2) (mccr sig1 sig2)
    where
      conjSig' ((i1,v1):s1) ((i2,v2):s2)
          | i1==i2
              = (i1,(v1 && v2)) : conjSig' s1 s2
          | otherwise
              = X.throw $ CpiException
                "CPi.Signals.conjSig: signals are not uniform!"
      conjSig' [] (s:sig) = X.throw $ CpiException
                            "CPi.Signals.conjSig: signals are not uniform!"
      conjSig' (s:sig) [] = X.throw $ CpiException
                            "CPi.Signals.conjSig: signals are not uniform!"
      conjSig' [] [] = []

-- The disjunction of two signals
disjSig :: Signal -> Signal -> Signal
disjSig sig1 sig2 = minCover $ disjSig' (mccl sig1 sig2) (mccr sig1 sig2)
    where
      disjSig' ((i1,v1):s1) ((i2,v2):s2)
          | i1==i2
              = (i1,(v1 || v2)) : disjSig' s1 s2
          | otherwise
              = X.throw $ CpiException
                "CPi.Signals.disjSig: signals are not uniform!"
      disjSig' [] (s:sig) = X.throw $ CpiException
                            "CPi.Signals.disjSig: signals are not uniform!"
      disjSig' (s:sig) [] = X.throw $ CpiException
                            "CPi.Signals.disjSig: signals are not uniform!"
      disjSig' [] [] = []

-- Give the covering range of the signal
cover :: Signal -> (Double,Double)
cover [] = (0,0)
cover [((l,h),_)] = (l,h)
cover (((l,_),_):sig) = (l,(\((_,h),_)->h)(last sig))

-- Remove False intervals from the signal
trueSig :: Signal -> Signal
trueSig [] = []
trueSig ((i,True):sig) = (i,True):(trueSig sig)
trueSig ((i,False):sig) = trueSig sig

-- Test if a signal is well-formed (has no gaps or overlaps)
wellformed :: Signal -> Bool
wellformed [] = False
wellformed [x] = True
wellformed (((_,u),_):s@((l,_),_):sig)
    | (u==l)
        = wellformed (s:sig)
    | otherwise
        = False

-- Take a True only signal and a desired cover and fill in False intervals
fillTrueSig :: (Double,Double) -> Signal -> Signal
fillTrueSig (mn,mx) [] = [((mn,mx),False)]
fillTrueSig (mn,mx) [s@((l,u),_)]
    | l>mn && u<mx
        = ((mn,l),False):s:((u,mx),False):[]
    | l>mn
        = ((mn,l),False):s:[]
    | u<mx
        = s:((u,mx),False):[]
    | otherwise
        = s:[]
fillTrueSig (mn,mx) (s1@((i,u),_):s2@((l,_),_):sig)
    | (i>mn)
        = ((mn,i),False):(fillTrueSig (i,mx) (s1:s2:sig))
    | (u>=l)
        = s1:(fillTrueSig (l,mx) (s2:sig))
    | otherwise
        = s1:((u,l),False):(fillTrueSig (l,mx) (s2:sig))

-- the Minkowski difference of an interval
minkDiff :: (Double,Double) -> (Double,Double) -> (Double,Double)
minkDiff (m,n) (a,b) = (m-b,n-a)

-- Shift a signal by [a,b] -- the Minkowski difference of each 
-- positive interval, union the positive Reals.
shiftSig :: (Double,Double) -> Signal -> Signal
shiftSig i s = minCover $ fillTrueSig (cover s) $ shift' (trueSig s) i
    where
      shift' [] _ = []
      shift' (((m,n),t):sig) (a,b)
          | a>b || a<0 || b<0
              = X.throw $ CpiException
                "CPi.Signals.shift only takes positive intervals"
          | c<0 && d<0
              = shift' sig (a,b)
          | c<0
              = ((0,d),t):(shift' sig (a,b))
          | otherwise
              = ((c,d),t):(shift' sig (a,b))
          where
            (c,d) = minkDiff (m,n) (a,b)

-- decompose a signal into unitary signals
decompose :: Signal -> [Signal]
decompose sig = map (fillTrueSig (cover sig)) (dc (trueSig sig))
    where
      dc [] = []
      dc (s:sig) = [s]:(dc sig)

-- compose a signal of given cover from a list of unitary signals
recompose :: [Signal] -> Signal
recompose [] = []
recompose (sig:sigs) 
    | all (\x-> cover x == cover sig) sigs
        = minCover $ foldr disjSig [(cover sig,False)] sigs
    | otherwise
        = X.throw $ CpiException
          "CPi.Signals.recompose requires all signals to have same cover"

-- temporal until of two signal
untilSig :: (Double,Double) -> Signal -> Signal -> Signal
untilSig (a,b) p q 
    | cover p == cover q
        = recompose 
          $ map (\x->conjSig x (shiftSig (a,b) (conjSig x q))) (decompose p)
    | otherwise
        = X.throw $ CpiException 
          "CPi.Signals.untilSig only takes signals of same cover"

-- produce the signal for a guarantee
-- NOTE: here we calculate the signal at every time point
--      of the original trace. Can we do better?
gteeSig :: Env 
        -> Process
        -> ODE.Solver 
        -> Trace
        -> Process 
        -> Formula 
        -> Signal
gteeSig env p solver trs q f 
    = minCover $ gteeSig' env p solver (traceInterval trs) q f trs
    where
      gteeSig' _ _ _ _ _ _ [] = []
      gteeSig' env p solver i q f trs 
          = ((traceStart trs, traceStart(traceNext trs)),
             modelCheckSig env solver Nothing
                               (compose (constructP p trs) q)
                               (traceLength trs,(0,simTime f)) f)
            : gteeSig' env p solver i q f (traceNext trs)
          

---------------------------
-- Tests
---------------------------

--all tests
tests = [test1,test2,test3,test4,test5,test6,test7,test8,test9,test10,
         test11,test12,test13,test14,test15,test16,test17,test18,test19,test20,
         test21,test22,test23,test24,test25,test26,test27]

-- min cover
test1 = not (uniform tSig1 tSig2)
test2 = uniform (mccl tSig1 tSig2) (mccr tSig1 tSig2)
-- conjunction/disjunction
test3 = conjSig tSig1 tSig2 == tConj12
test4 = disjSig tSig1 tSig2 == tDisj12
test5 = conjSig tSig3 tSig4 == tConj34
test6 = disjSig tSig3 tSig4 == tDisj34
-- signals <-> True only signals
test7 = fillTrueSig (cover tSig1) (trueSig tSig1) == tSig1 
test8 = fillTrueSig (cover tSig2) (trueSig tSig2) == tSig2
test9 = fillTrueSig (cover tSig3) (trueSig tSig3) == tSig3
test10 = fillTrueSig (cover tSig4) (trueSig tSig4) == tSig4
-- shift
test11 = shiftSig (0,1) tSig1 == tSig1shift01
test12 = shiftSig (0,2) tSig1 == tSig1shift02
test13 = shiftSig (0,3) tSig1 == tSig1shift03
test14 = shiftSig (1,2) tSig1 == tSig1shift12
-- until
test15 = decompose tSigP == [tSigP1,tSigP2]
test16 = conjSig tSigP1 tSigQ == tConjP1Q
test17 = conjSig tSigP2 tSigQ == tConjP2Q
test18 = shiftSig (1,2) tConjP1Q == tShift12ConjP1Q 
test19 = shiftSig (1,2) tConjP2Q == tShift12ConjP2Q 
test20 = conjSig tShift12ConjP1Q tSigP1 == tConjR1P1
test21 = conjSig tShift12ConjP2Q tSigP2 == tConjR2P2
test22 = disjSig tConjR1P1 tConjR2P2 == tPUntilQ
test23 = recompose [tConjR1P1, tConjR2P2] == tPUntilQ
test24 = untilSig (1,2) tSigP tSigQ == tPUntilQ

-- relative bounds
test25 = shiftSig (0,2) tSigL == tShift2L
test26 = conjSig tSigH tShift2L == tHConjFL
test27 = shiftSig (0,5) tHConjFL == tShift5HFL

-------------
-- Test data
-------------

tSig1 = [((0,1),False),((1,3),True),((3,6),False),((6,8),True)] :: Signal
tSig2 = [((0,2),False),((2,7),True),((7,8),False)] :: Signal
tConj12 = [((0,2),False),((2,3),True),((3,6),False),
           ((6,7),True),((7,8),False)] :: Signal
tDisj12 = [((0,1),False),((1,8),True)] :: Signal
tSig3 = [((0,2),True),((2,3),False),((3,5),True),((5,7),False)] :: Signal
tSig4 = [((0,1),True),((1,2),False),((2,4),True),
         ((4,5),False),((5,7),True)] :: Signal
tConj34 = [((0,1),True),((1,3),False),((3,4),True),((4,7),False)] :: Signal 
tDisj34 = [((0,7),True)] :: Signal
tSig1shift01 = [((0.0,3.0),True),((3.0,5.0),False),((5.0,8.0),True)]
tSig1shift02 = [((0.0,3.0),True),((3.0,4.0),False),((4.0,8.0),True)]
tSig1shift03 = [((0.0,8.0),True)]
tSig1shift12 = [((0.0,2.0),True),((2.0,4.0),False),
                ((4.0,7.0),True),((7.0,8.0),False)]

tSigP = [((0,1),False),
         ((1,3),True),
         ((3,4),False),
         ((4,7),True),
         ((7,8),False)] :: Signal
tSigQ = [((0,4),False),
         ((4,5),True),
         ((5,6),False),
         ((6,8),True)] :: Signal
tSigP1 = [((0,1),False),
          ((1,3),True),
          ((3,8),False)] :: Signal
tSigP2 = [((0,4),False),
          ((4,7),True),
          ((7,8),False)] :: Signal
tConjP1Q = [((0,8),False)] :: Signal
tConjP2Q = [((0,4),False),
            ((4,5),True),
            ((5,6),False),
            ((6,7),True),
            ((7,8),False)] :: Signal
tShift12ConjP1Q = tConjP1Q -- = R1
tShift12ConjP2Q = [((0,2),False), -- = R2
                   ((2,6),True),
                   ((6,8),False)] :: Signal 
tConjR1P1 = tConjP1Q
tConjR2P2 = [((0,4),False),
             ((4,6),True),
             ((6,8),False)] :: Signal
tPUntilQ = tConjR2P2

tSigH = [((0,4),False),
         ((4,5),True),
         ((5,10),False)] :: Signal
tSigL = [((0,4),True),
         ((4,5),False),
         ((5,10),True)] ::Signal
tShift2L = [((0,10),True)] :: Signal -- = FL
tHConjFL = [((0,4),False),
            ((4,5),True),
            ((5,10),False)] :: Signal -- = HFL
tShift5HFL = [((0,5),True),
              ((5,10),False)] :: Signal