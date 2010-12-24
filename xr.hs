{-# LANGUAGE FlexibleInstances #-}
-- (uncomment to make file executable)
--
-- "X-module function Reference grapher"
--
-- Reads a bunch of Erlang code and produces a module dependency graph.
-- A simple but powerful tool for static analysis of source code.
--
-- FEATURES:
--  - unknown modules shown as boxes, known as ellipses
--  - there's an ignore list for "pure" modules with no interesting side
--    effects
--  - by using core erlang precompilation, eunit/debug code is properly
--    taken into account (I think!)
--
-- DEPENDENCIES:
--  - GHC, a recent Haskell Platform should do. You'll need
-- to pull the following packages via cabal-install:
--      amtal@kos:~$ cabal update
--      amtal@kos:~$ cabal install filemanip
--      amtal@kos:~$ cabal install coreerlang
--  - GraphViz, see your package manager of choice
--  - Won't clean up after itself on Windows due to using `rm`
--
-- CAUTION: hacky work in progress: lists, strings, IO everywhere
--
-- TODO:
--
-- separate types for walking Exp and walking everything else, in order
--   to type-guarantee that Exp won't be expanded twice (and thus not
--   pattern matched) on accident
--
-- group modules into subgraph_clusters, according to:
--      purity (unlinked)
--      OTP?
--      known side effects
--      logging?
-- this organizes and changes the shape of the graph
-- should be used to bring *related* modules together, if the relation
-- isn't apparent in the links (OTP) (might clutter things - color/shape
-- instead?)
--
-- or just use type annotations to group them (a -package mod tag?)
-- definitely add a -pure mod tag, annotating either funcs or entire module
-- (pure modules can be hidden from mod. dep graph, not interesting)
--
--
-- pure ignore list as a runtime option, rather than hardcode
-- modify ignoring *test.erl via cmd line switch
-- have option to not delete .core files (debug)
-- 
-- something to avoid constant recompile cost...
-- graph colouring to trace flow through multiple modules?
-- have a "focus" mode that displays major neighbors of node only
--      (to conform to 7+/-2... could auto-grouping also do this?)
--
-- watch HRL file dependencies (and that's a regex thing)
-- detect bad record sharing? ...looks like that'd be a whole separate
--  thing for static analysis of HRL files
--
-- on a similar trend, are supervisor dependencies worth tracking?
-- are they even trackable, due to potential dynamic child adding?
--
--
-- AUTHOR: Amtal <alex.kropivny@gmail.com>
-- LICENSE: give credit if using significant chunks. If you find a way
-- to make money from it, tell me how. Otherwise, do whatever yo.
import Control.Monad (when)
-- File Wrangling
import System.FilePath.Find
import System.Process (runCommand, waitForProcess)
import System.Exit (ExitCode(..))
-- Parsing and Filtering
import Language.CoreErlang.Parser
import Language.CoreErlang.Syntax
import Prelude hiding (exp)
-- GraphViz Generation
import Data.List hiding (find)
-- Debugging
import Debug.Trace

-- CONFIG: (command line arguments are a sign of weakness)
-- The point of these graphs is to identify important dependencies.
-- Leaf modules with no side effects rarely count as such.
ignoredModules = [ "dict","sets","gb_sets","lists", "proplists",
                   "string", "io_lib", "re", "eunit",
                   -- these aren't pure, but used everywhere so I've
                   -- got no choice but to ignore them
                   "gen_server", "gen_event",
                   -- there's plenty of side effects in erlang, but
                   -- it's also so full of pure funcs it clutters
                   -- graphs (TODO: have a function list for this,
                   -- so spawn and whatnot gets watched but not
                   -- is_atom and whatnot)
                   "erlang"]
-- Things like dict and lists are good examples, while erlang and
-- calendar bad examples due to introducing new processes and the notion
-- of time.


-- * File Wrangling (looks kinda like a Make script, hmmm...)

main = do
    putStrLn "Compiling into intermediate format..."
    find always code "." >>= mapM erl2core
    putStrLn "Parsing files..."
    mods <- find always core "." >>= mapM process 
    putStrLn "Building graph..."
    graph $ concat mods
    return ()
        where
    code = extension ==? ".erl"
        &&? fileName /~? "*tests.erl"
    core = extension ==? ".core"

erl2core :: FilePath -> IO ()
erl2core fname = do
    ret <- exec $ "erlc -I ../include +to_core "++fname
    when (ret/=ExitSuccess) (putStrLn $ "\tError compiling "++fname)

exec cmd = runCommand cmd >>= waitForProcess



-- * Common Data Structures

data Mfa = Mfa String String Int deriving (Show,Read,Eq)
data Call = Call Mfa Mfa deriving (Show,Read,Eq)



-- * Parsing and Filtering

process :: FilePath -> IO [[Call]]
process fname = do
    s <- readFile fname
    exec $ "rm "++fname
    case parseModule s of
        Left err -> do
            putStrLn $ "Error parsing "++fname++": "++show err
            return []
        Right tree -> 
            return [extractCrossRefs tree]

cmap = concatMap -- shorthand, we'll need it

-- recursively exp tree via pattern matching, looking for
-- ModCalls (todo: generalize this via something like a Functor)
extractCrossRefs :: Ann Module -> [Call]
extractCrossRefs tree = mod (nna tree) where
    mod (Module (Atom from_mod) _ _ funs) = calls from_mod funs

calls from_mod funs = collect `cmap` map funDef funs where
    collect :: Exp -> [Call]
    collect e@(ModCall (m,f) args) = collect `cmap` climb e 
        ++ [Call (Mfa from_mod "idk" 0) (Mfa (get m) (get f) (length args))] 
            where
        get (Exp(Constr(Lit(LAtom(Atom s))))) = s
        get (Exp(Constr(Var s))) = s
    collect e@(App f args) = collect `cmap` climb e
        ++ [Call (Mfa from_mod "idk" 0) (Mfa from_mod (get f) (length args))] 
            where
        get (Exp(Constr(Fun(Function(Atom s,_))))) = s
        get (Exp(Constr(Var s))) = s
        get other = trace (show other) undefined
    collect e = collect `cmap` climb e

-- annotations show up everywhere and we don't care
-- (what are they even for, comments? line #s?)
nna :: Ann a -> a
nna (Ann m _) = m
nna (Constr m) = m

funDef :: FunDef -> Exp
funDef (FunDef _ a) = nna a



-- Generalized syntax tree climbing
class Tree a where climb :: a -> [Exp]
-- Exp forms the bulk of the AST, recursively referring to
-- itself via Exps (which are just one or more annotated Exp)
instance Tree Exps where
    climb (Exp a) = [nna a]
    climb (Exps as) = nna `map` nna as
instance Tree Exp where
    climb (App ex exs) = climb ex ++ cmap climb exs
    climb (Lambda _ ex) = climb ex
    climb (Seq ex ex') = climb ex ++ climb ex'
    climb (Let (_,ex) ex') = climb ex ++ climb ex'
    climb (LetRec fs ex) = map funDef fs ++ climb ex
    climb (Case ex as) = climb ex ++ cmap (climb . nna) as
    climb (Rec as _) = cmap (climb . nna) as
    climb (Tuple exs) = cmap climb exs
    climb (List l) = climb l where
    climb (Binary bs) = cmap climb bs where
    climb (ModCall (_,_) args) = cmap climb args 
    climb (Op _ es) = cmap climb es
    climb (Try es (_, es') (_, es'')) = cmap climb (es:es':es'':[])
    climb (Catch es) = climb es
    -- everything else can't contain side effects, and can be
    -- ignored (probably, surely I got it all)
    climb _ = []
-- some of the following probably deserve a 'where' not an instance...
instance Tree Alt where
    climb (Alt _ guard ex) = climb guard ++ climb ex
instance Tree Guard where -- should be pure, but may as well...
    climb (Guard exs) = climb exs
instance Tree (List Exps) where
    climb (L es) = cmap climb es -- no guarantees on order...
    climb (LL es e) = climb e ++ cmap climb es
instance Tree (BitString Exps) where
    climb (BitString _ es) = cmap climb es



-- * GraphViz Generation 
--
-- Note: combining Data.Graph.Inductive and Data.GraphViz may produce
-- cromulent results. Then again, it might just be a waste of time.
-- 
-- Would this allow better control of graph attributes than raw output?


graph :: [[Call]] -> IO ()
graph ms = do
    writeFile "xr.dot" (showGraph . mkGraph $ ms)
    exec "dot -Tpng xr.dot > xr.png"
    return ()
     
data Graph = Node String NType
           | Arrow String String AType
           | Comment String
           deriving (Show,Read,Eq,Ord)
data NType = Internal | External deriving (Show,Read,Eq,Ord)
data AType = Triangle | Ball | Label String deriving (Show,Read,Eq,Ord)

showGraph :: [Graph]->String
showGraph g = concat . intersperse "\n" 
            $ ["digraph xr {"]++map pGraph g++["}"] where
    pGraph (Node s Internal) = "\t"++esc s++" [shape=ellipse]"
    pGraph (Node s External) = "\t"++esc s++" [shape=box]"
    pGraph (Arrow m m' t) = esc m++"->"++esc m'++style t where
        style Ball = " [arrowhead=dot]"
        style Triangle = ""
        style (Label s) = "[label="++esc s++"]"
    pGraph (Comment s) = "/* "++s++" */"
    esc s = '\"':s++"\""


ppMfa (Mfa m f a) = m++":"++f++"/"++show a

mkGraph :: [[Call]] -> [Graph]
mkGraph ms = mods++calls where
    -- set up module styles before drawing calls
    mods :: [Graph]
    mods = conv internal Internal ++ conv external External
            where
        conv ss shp = map (flip Node shp) ss
        internal = map head . group . sort -- remove duplicates
                 . concat $ (map.map) (\(Call from _)->ppMfa from) ms
        external = map head . group . sort -- remove duplicates
                 $ filter (not . flip elem internal) called
        called = filter bad 
               . concat 
               . map (map getTarg) 
               $ ms
        getTarg (Call _ t) = ppMfa t
        bad "-" = False -- I don't understand how this happens
        bad _ = True -- nor care enough to figure it out now
    -- call edges
    calls :: [Graph]
    calls = duplicatesToComments
          . concat . map modCalls $ ms 
    modCalls mCalls = map call mCalls where
        call (Call from to@(Mfa m _ _))
            | m `elem` ignoredModules = Comment $ "ignored call to "++m
            | otherwise = Arrow (ppMfa from) (ppMfa to) Triangle where
    -- hideously hacky multiple calls->single line with number processing
    duplicatesToComments :: [Graph]->[Graph]
    duplicatesToComments = map f . group . sort where
        f l@((Arrow s s' _):_) = Arrow s s' a where
            a | length l==1  = Triangle
              | otherwise = Label . show . length $ l
        f other = head other
