{-# LANGUAGE  FlexibleInstances, BangPatterns, MultiParamTypeClasses, FlexibleContexts #-}

module CPi.Processes (Process(..), Affinity(..), ProcessVect,
  ConcreteAffinityNetwork, P, D, P', D', concretifyModel, partial, conc,
  direct, react, hide, networkSites, actions, dPdt, partial', dPdt',
  tracesGivenNetwork, speciesVar) where

import Prelude hiding ((*>), (<*))
import CPi.AST
import CPi.Base
import CPi.Transitions
import qualified Data.List as L
import qualified Data.HashMap.Strict as H
import qualified Data.Map as M
import CPi.Vector
import CPi.Symbolic (SymbolicExpr, var)
import Data.Maybe
import Data.Bifunctor
-- import Debug.Trace
trace :: String -> a -> a
trace _ = id

type SymbConc = SymbolicExpr

-- Process vectors over k
type ProcessVect k = Vect Species k
-- Interaction vectors over k
type InteractionVect k = Vect (Tensor (Tensor Species Abstraction) [Prefix]) k
-- Direction vectors over k
type DirectionVect k = Vect (Tensor Species Abstraction) k

-- Process space
type P = ProcessVect Conc
-- Potential interaction space
type D = InteractionVect Conc

-- Process space
type P' = ProcessVect SymbConc
-- Potential interaction space
type D' = InteractionVect SymbConc

data Process k = Mixture [(k, Species)]
             | React (ConcreteAffinityNetwork k) (Process k)

-- A CPi model with all of the variables looked up
type ConcreteModel k = (Env, M.Map String (ConcreteAffinityNetwork k, P))

powerset :: [a] -> [[a]]
powerset []     = [[]]
powerset (x:xs) = powerset xs ++ map (x:) (powerset xs)

-- Core process semantics

conc :: (Vector k (InteractionVect k)) => [Prefix] -> InteractionVect k -> k
conc s (Vect v) = norm $ Vect $ H.filterWithKey atS v
  where atS (_ :* _ :* t) _ = s == t

direct :: (Vector k (InteractionVect k), Vector k (DirectionVect k)) => [Prefix] -> InteractionVect k -> Vect (Tensor Species Abstraction) k
direct l v = normalize (direct' >< v)
  where direct' (s :* s' :* m) = fromInteger (delta l m) |> vect (s :* s')

hide :: (Vector k (InteractionVect k)) => [[Prefix]] -> InteractionVect k -> InteractionVect k
hide toHide (Vect v) = Vect $ H.filterWithKey shouldHide v
  where shouldHide (_ :* _ :* sites) _ = sites `notElem` toHide

primes :: Species -> [Species]
primes (Par _ _ ss) = L.concatMap primes ss
primes s = [s]

embed :: (Vector k (ProcessVect k)) => Species -> ProcessVect k
embed spec = fromList $ map (\s -> (1, s)) $ filter (/=Nil) $ primes $ normalForm spec

react :: (Vector k (DirectionVect k), Nullable (DirectionVect k), Expression k) =>
         [DirectionVect k] -> ProcessVect k
-- it is very important that reactions ignore zero vectors, otherwise we get
-- 0 (when we should just get the reaction of those actions which are present)
-- how does this work in this the symbolic case?
react = multilinear react' <$> filter (/=vectZero)
  where react' xs = embed (concretify $
                    foldl (<|>) (mkAbsBase Nil) (map target xs)) +>
                    (-1.0) |> foldl (+>) vectZero (map (embed.source) xs)
        source (spec :* _) = spec
        target (_ :* spec') = spec'

actions :: (Vector k (DirectionVect k), Nullable (DirectionVect k), Expression k, Show k) =>
           ConcreteAffinityNetwork k -> InteractionVect k -> ProcessVect k
actions network !potential = L.foldl' (+>) vectZero [
  let concs   = map (`conc` potential') sites'
      directs = map (`direct` potential') sites'
      sites'  = map (L.sort . map Unlocated) sites
      magnitude = law concs
      effect  = react directs
  in trace(show magnitude ++ " * " ++ show (zip3 sites' concs directs) ++ " : " ++ pretty effect) $ if not $ isnull magnitude then magnitude |> effect else vectZero
  --  if any (not.isnull) concs then law concs |> react directs else vectZero
  | ConcreteAffinity law sites <- network ]
  where Vect h     = potential
        potential' = Vect $ H.filter (not.isnull) h
        --  ((>1e-12).abs) h

partial' :: (Vector k (InteractionVect k), Expression k) => (Species -> MTS) -> ProcessVect k -> InteractionVect k
partial' tr = (partial'' ><)
  where partial'' spec = fromList [(1, s :* s' :* L.sort a)
                           | Trans s a s' <- simplify $ tr spec]

dPdt' :: (Vector k (ProcessVect k), Show k, Expression k) => (Species -> MTS) -> ConcreteAffinityNetwork k -> ProcessVect k -> ProcessVect k
dPdt' tr network p = trace ("part = " ++ pretty part ++ ", acts = " ++ pretty acts)
                           acts
  where acts = actions network part
        part = partial' tr p

-- Helpers for handling models

tracesGivenNetwork :: ConcreteAffinityNetwork k -> Env -> Species -> MTS
tracesGivenNetwork network = trace ("prefLists = " ++ show prefLists) (transFiltered validPref)
  where
    prefLists = L.nub $ L.sort $ map (L.sort . map prefName) $ L.concatMap (map (map Unlocated) . cAffSites) network
    prefListSubsets = L.nub $ L.sort $ L.concatMap powerset prefLists
    validPref :: PrefixFilter
    validPref x = trace ("testing potential " ++ show x) (L.sort x `elem` prefListSubsets)

concretifyAffSpec :: CPiModel k -> AffinityNetworkSpec
                              -> Either String (ConcreteAffinityNetwork k)
concretifyAffSpec model@(Defs _ a _ _) (AffinityNetworkAppl name rates)
  = case M.lookup name a of
      Just (AffinityNetworkDef params body) ->
        if length rates == length rates
        then networkFromList [applyAff model aff params rates | aff <- body]
        else Left $ "Affinity network " ++ name ++ " applied to the "
                     ++ "wrong number of arguments."
      Nothing -> Left $ "Affinity network " ++ name ++ " does not exist."
    where networkFromList :: [Either String (ConcreteAffinity k)]
                             -> Either String (ConcreteAffinityNetwork k)
          networkFromList affsOrErrors = case errors of
                                           []    -> Right affs
                                           (e:_) -> Left e
            where errors = [e | Left e <- affsOrErrors]
                  affs   = [aff | Right aff <- affsOrErrors]

applyAff :: CPiModel k -> Affinity -> [String] -> [Rate] -> Either String (ConcreteAffinity k)
applyAff model (Affinity rls sites) params rates
  = second (`ConcreteAffinity` map L.sort sites) $ applyRateLawSpec model rls params rates

applyRateLawSpec :: CPiModel k -> RateLawSpec -> [String] -> [Rate]
                             -> Either String (RateLaw k)
applyRateLawSpec (Defs _ _ m _) (RateLawAppl name params) affParams rates
  = case M.lookup name m of
      Nothing -> Left $ "Kinetic law " ++ name ++ " does not exist."
      Just rlf -> if any isNothing args
                  then Left $ "Kinetic law " ++ name ++ " applied to "
                               ++ "variables which do not exist."
                  else Right $ rlf $ map (fromMaybe undefined) args
    where vals = zip affParams rates
          applyRate (RateLawParamVal x) = Just x
          applyRate (RateLawParamVar n) = L.lookup n vals
          args = map applyRate params

concretifyProcess :: CPiModel k -> AbstractProcess
                     -> Either String (ConcreteAffinityNetwork k, P)
concretifyProcess model (Process affSpec concSpecs)
  = case networkOrError of
      Right network -> Right (network, p)
      Left err    -> Left err
  where p              = fromList [(c, normalForm s) | (c,s) <- concSpecs]
        networkOrError = concretifyAffSpec model affSpec

concretifyModel :: CPiModel k -> Either String (ConcreteModel k)
concretifyModel model@(Defs env _ _ p)
  = case errors of
      []            -> Right (env, processes)
      ((name, e):_) -> Left $ "Error found in process definition " ++ name
                               ++ ":\n" ++ e
  where processes = M.fromList [ (name,  process)
                    | (name, Right process) <- cprocs]
        cprocs    = M.toList $ fmap (concretifyProcess model) p
        errors    = [(name, e) | (name, Left e) <- cprocs]

networkSites :: ConcreteAffinityNetwork k -> [[Prefix]]
networkSites = L.concatMap (map (map Unlocated) . cAffSites)

partial :: (Vector k (InteractionVect k)) => Env -> Process k -> InteractionVect k
partial env (Mixture ((c,spec):xs)) = fromList
                                      [(c, s :* s' :* a)
                                      | Trans s a s' <- simplify $ trans env spec]
                                      +> partial env (Mixture xs)
partial env (React network p) = hide (networkSites network) $ partial env p
partial _ (Mixture []) = vectZero

speciesVar :: Species -> SymbolicExpr
speciesVar s = var $ "[" ++ pretty (normalForm s) ++ "]"

embedProcess :: (Vector k (ProcessVect k)) => Process k -> ProcessVect k
embedProcess (Mixture ps) = fromList ps

dPdt :: (Vector k (ProcessVect k), Show k, Expression k) => Env -> Process k -> ProcessVect k
dPdt _ (Mixture _) = vectZero
dPdt env (React network p) = dPdt' tr network pro
  where pro = embedProcess p
        -- tr  = trans env
        tr = tracesGivenNetwork network env
-- TODO: nested Mixtures inside Reacts