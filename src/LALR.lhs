-----------------------------------------------------------------------------
$Id: LALR.lhs,v 1.22 2001/09/26 13:07:59 simonmar Exp $

Generation of LALR parsing tables.

(c) 1993-1996 Andy Gill, Simon Marlow
(c) 1997-2001 Simon Marlow
-----------------------------------------------------------------------------

> module LALR
>	(genActionTable, genGotoTable, genLR0items, precalcClosure0,
>	 propLookaheads, calcLookaheads, mergeLookaheadInfo, countConflicts,
>	 Lr0Item, Lr1Item)
>	where

> import GenUtils
> import Set
> import Grammar

> import Array

#if defined(__GLASGOW_HASKELL__)

> import ST

#if __GLASGOW_HASKELL__ < 402
#define newSTArray newArray
#define readSTArray readArray
#define writeSTArray writeArray
#define freezeSTArray freezeArray

> import MutableArray
#endif

#endif

This means rule $a$, with dot at $b$ (all starting at 0)

> type Lr0Item = (Int,Int)			-- (rule, dot)

> type Lr1Item = (Int,Int,Set Name)		-- (rule, dot, lookahead)
> type RuleList = [Lr0Item]

-----------------------------------------------------------------------------
Generating the closure of a set of LR(0) items

Precalculate the rule closure for each non-terminal in the grammar,
using a memo table so that no work is repeated.

> precalcClosure0 :: Grammar -> Name -> RuleList
> precalcClosure0 g = 
>	\n -> case lookup n info' of
>		Nothing -> []
>		Just c  -> c
>  where
>
>	info' = map (\(n,rules) -> (n,map (\rule -> (rule,0)) rules)) info
>	info = mkClosure (==) (\f -> map (follow f) f)
>			(map (\nt -> (nt,lookupProdsOfName g nt)) nts)

>	follow f (nt,rules) = (nt, foldr union rules (map (followNT f) rules))

>	followNT f rule = 
>		case findRule g rule 0 of
>			Just nt	| nt >= firstStartTok && nt < fst_term ->
>				case lookup nt f of
>					Just rs -> rs
>					Nothing -> error "followNT"
>			_ -> []

>	nts = non_terminals g
>	fst_term = first_term g

> closure0 :: Grammar -> (Name -> RuleList) -> Set Lr0Item -> Set Lr0Item
> closure0 g closureOfNT set = mkSet (foldr addRules emptySet set)
>    where
> 	fst_term = first_term g
>	addRules rule set = union (mkSet (rule : closureOfRule rule)) set
> 
>	closureOfRule (rule,dot) = 
>           case findRule g rule dot of 
>           	(Just nt) | nt >= firstStartTok && nt < fst_term 
>		   -> closureOfNT nt
>               _  -> []

-----------------------------------------------------------------------------
Generating the closure of a set of LR(1) items

> closure1 :: Grammar -> ([Name] -> Set Name) -> [Lr1Item] -> [Lr1Item]
> closure1 g first set
>       = fst (mkClosure (\(_,new) _ -> null new) addItems ([],set))
>	where
>	fst_term = first_term g

>	addItems :: ([Lr1Item],[Lr1Item]) -> ([Lr1Item],[Lr1Item])
>	addItems (old_items, new_items) = (new_old_items, new_new_items)
>	  where
>		new_old_items = new_items `union_items` old_items
>		new_new_items = subtract_items 
>				   (foldr union_items [] (map fn new_items))
>					new_old_items

>		fn :: Lr1Item -> [Lr1Item]
>		fn (rule,dot,as) =
>		    case lookupProdNo g rule of { (name,lhs,_,_) ->
>		    case drop dot lhs of
>			(b:beta) | b >= firstStartTok && b < fst_term ->
>			    let terms = concatMapSet 
>						(\a -> first (beta ++ [a])) as
>			    in
>			    [ (rule,0,terms) | rule <- lookupProdsOfName g b ]
>			_ -> []
>		    }

Subtract the first set of items from the second.

> subtract_items :: [Lr1Item] -> [Lr1Item] -> [Lr1Item]
> subtract_items items1 items2 = foldr (subtract_item items2) [] items1

These utilities over item sets are crucial to performance.

Stamp on overloading with judicious use of type signatures...

> subtract_item :: [Lr1Item] -> Lr1Item -> [Lr1Item] -> [Lr1Item]
> subtract_item [] i result = i : result
> subtract_item ((rule,dot,as):items) i@(rule',dot',as') result =
>	case compare rule' rule of
>		LT -> i : result
>		GT -> carry_on
>		EQ -> case compare dot' dot of
>			LT -> i : result
>			GT -> carry_on
>			EQ -> case subtractSet as' as of
>				[] -> result
>				bs -> (rule,dot,bs) : result
>  where
>	carry_on = subtract_item items i result

Union two sets of items.

> union_items :: [Lr1Item] -> [Lr1Item] -> [Lr1Item]
> union_items is [] = is
> union_items [] is = is
> union_items (i@(rule,dot,as):is) (i'@(rule',dot',as'):is') =
>	case compare rule rule' of
>		LT -> drop_i
>		GT -> drop_i'
>		EQ -> case compare dot dot' of
>			LT -> drop_i
>			GT -> drop_i'
>			EQ -> (rule,dot,as `union_Int` as') : union_items is is'
>  where
>	drop_i  = i  : union_items is (i':is')
>	drop_i' = i' : union_items (i:is) is'

-----------------------------------------------------------------------------
goto(I,X) function

The input should be the closure of a set of kernel items I together with
a token X (terminal or non-terminal.  Output will be the set of kernel
items for the set of items goto(I,X)

> gotoClosure :: Grammar -> Set Lr0Item -> Name -> Set Lr0Item
> gotoClosure gram i x = concatMapSet fn i
>    where
>       fn (rule_no,dot) =
>          case findRule gram rule_no dot of
>               Just t | x == t -> singletonSet (rule_no,dot+1)
>               _ -> emptySet           

-----------------------------------------------------------------------------
Generating LR0 Item sets

The item sets are generated in much the same way as we find the
closure of a set of items: we use two sets, those which have already
generated more sets, and those which have just been generated.  We
keep iterating until the second set is empty.

The addItems function is complicated by the fact that we need to keep
information about which sets were generated by which others.

> type ItemSetWithGotos = (Set Lr0Item, [(Name,Int)])

> genLR0items :: Grammar -> (Name -> RuleList) -> [ItemSetWithGotos]
> genLR0items g precalcClosures
>	= fst (mkClosure (\(old,new) _ -> null new)
>               addItems
>                 (([],startRules)))
>  where

>    n_starts = length (starts g)
>    startRules :: [Set Lr0Item]
>    startRules = [ singletonSet (rule,0) | rule <- [0..n_starts] ]

>    tokens = non_terminals g ++ terminals g

>    addItems :: ([ItemSetWithGotos], [Set Lr0Item])
>	      -> ([ItemSetWithGotos], [Set Lr0Item])
>	      
>    addItems (oldSets,newSets) = (newOldSets, reverse newNewSets)
>     where
>	
>	newOldSets = oldSets ++ (zip newSets intgotos)

>	itemSets = map fst oldSets ++ newSets

First thing to do is for each set in I in newSets, generate goto(I,X)
for each token (terminals and nonterminals) X.

>	gotos :: [[(Name,Set Lr0Item)]]
>	gotos = map (filter (not . isEmptySet . snd))
>	    (map (\i -> let i' = closure0 g precalcClosures i in
>	    		[ (x,gotoClosure g i' x) | x <- tokens ]) newSets)

Next, we assign each new set a number, which is the index of this set
in the list of sets comprising all the sets generated so far plus
those generated in this iteration.  We also filter out those sets that
are new, i.e. don't exist in the current list of sets, so that they
can be added.

We also have to make sure that there are no duplicate sets in the
*current* batch of goto(I,X) sets, as this could be disastrous.  I
think I've squished this one with the '++ reverse newSets' in
numberSets.

numberSets is built this way so we can use it quite neatly with a foldr.
Unfortunately, the code's a little opaque.

>	numberSets 
>		:: [(Name,Set Lr0Item)] 
>		-> (Int,
>		    [[(Name,Int)]],
>		    [Set Lr0Item])
>		-> (Int, [[(Name,Int)]], [Set Lr0Item])
>
>	numberSets [] (i,gotos,newSets) = (i,([]:gotos),newSets)
>	numberSets ((x,gotoix):rest) (i,g:gotos,newSets)
>	   = numberSets rest
>	   	(case indexInto 0 gotoix (itemSets ++ reverse newSets) of
>			Just j  -> (i,  ((x,j):g):gotos, newSets)
>			Nothing -> (i+1,((x,i):g):gotos, gotoix:newSets))

Finally, do some fiddling around to get this all in the form we want.

>	intgotos :: [[(Name,Int)]]
>	newNewSets  :: [Set Lr0Item]
>	(_, ([]:intgotos), newNewSets) =
>		foldr numberSets (length newOldSets, [[]], []) gotos

> indexInto :: Eq a => Int -> a -> [a] -> Maybe Int
> indexInto _ _ []		   = Nothing
> indexInto i x (y:ys) | x == y    = Just i
>		       | otherwise = indexInto (i+1) x ys

-----------------------------------------------------------------------------
Computing propagation of lookaheads

ToDo: generate this info into an array to be used in the subsequent
calcLookaheads pass.

> propLookaheads 
>	:: Grammar
>	-> [(Set Lr0Item,[(Name,Int)])]		-- LR(0) kernel sets
>	-> ([Name] -> Set Name)			-- First function
>	-> (
>		[(Int, Lr0Item, Set Name)],	-- spontaneous lookaheads
>		Array Int [(Lr0Item, Int, Lr0Item)]	-- propagated lookaheads
>	   )

> propLookaheads gram sets first = (concat s, array (0,length sets - 1) 
>			[ (a,b) | (a,b) <- p ])
>   where

>     (s,p) = unzip (zipWith propLASet sets [0..])

>     propLASet (set,goto) i = (concat s, (i, concat p))
>	where

>	  (s,p) = unzip (map propLAItem (setToList set))

>	  propLAItem item@(rule,dot) = (spontaneous, propagated)
>	    where

>		j = closure1 gram first [(rule,dot,singletonSet dummyTok)]

>		spontaneous = concat [ 
>		 (case findRule gram rule dot of
>		     Nothing -> []
>		     Just x  -> case lookup x goto of
>			 	  Nothing -> error "spontaneous"
>				  Just k  ->
>					case filter (/= dummyTok) (setToList ts) of
>					   [] -> []
>					   ts' -> [(k, (rule, dot+1), ts')])
>			| (rule,dot,ts) <- j ]

>		propagated = concat [
>		 (case findRule gram rule dot of
>		     Nothing -> []
>		     Just x  -> case lookup x goto of
>				  Nothing -> error "propagated"
>				  Just k  -> [(item, k, (rule, dot+1))])
>			| (rule,dot,ts) <- j, dummyTok `elem` (setToList ts) ]

-----------------------------------------------------------------------------
Calculate lookaheads

#if defined(__GLASGOW_HASKELL__)

Special version using a mutable array for GHC.

> calcLookaheads
>	:: Int					-- number of states
>	-> [(Int, Lr0Item, Set Name)]		-- spontaneous lookaheads
>	-> Array Int [(Lr0Item, Int, Lr0Item)]	-- propagated lookaheads
>	-> Array Int [(Lr0Item, Set Name)]

> calcLookaheads n_states spont prop
>	= runST (do
>	    array <- newSTArray (0,n_states) []
>	    propagate array (foldr fold_lookahead [] spont)
>	    freezeSTArray array
>	)

>   where
>	propagate array []  = return ()
>	propagate array new = do 
>		let
>		   items = [ (i,item'',s) | (j,item,s) <- new, 
>				            (item',i,item'') <- prop ! j,
>				            item == item' ]
>		new_new <- get_new array items []
>		add_lookaheads array new
>		propagate array new_new

This function is needed to merge all the (set_no,item,name) triples
into (set_no, item, set name) triples.  It can be removed when we get
the spontaneous lookaheads in the right form to begin with (ToDo).

> add_lookaheads array [] = return ()
> add_lookaheads array ((i,item,s) : lookaheads) = do
>	las <- readSTArray array i
>	writeSTArray array i (add_lookahead item s las)
>	add_lookaheads array lookaheads

> get_new array [] new = return new
> get_new array (l@(i,item,s):las) new = do
>	state_las <- readSTArray array i
>	get_new array las (get_new' l state_las new)

> add_lookahead :: Lr0Item -> Set Name -> [(Lr0Item,Set Name)] ->
> 			[(Lr0Item,Set Name)]
> add_lookahead item s [] = [(item,s)]
> add_lookahead item s (m@(item',s') : las)
>	| item == item' = (item, s `union_Int` s') : las
>	| otherwise     = m : add_lookahead item s las

> get_new' :: (Int,Lr0Item,Set Name) -> [(Lr0Item,Set Name)] ->
>		 [(Int,Lr0Item,Set Name)] -> [(Int,Lr0Item,Set Name)]
> get_new' l [] new = l : new
> get_new' l@(i,item,s) (m@(item',s') : las) new
>	| item == item' =
>		let s'' = filter (`notElem` s') s in
>		if null s'' then new else
>		((i,item,s''):new)
>	| otherwise = 
>		get_new' l las new

> fold_lookahead :: (Int,Lr0Item,Set Name) -> [(Int,Lr0Item,Set Name)]
>		-> [(Int,Lr0Item,Set Name)]
> fold_lookahead l [] = [l]
> fold_lookahead l@(i,item,s) (m@(i',item',s'):las)
>  	| i == i' && item == item' = (i,item, s `union_Int` s'):las
>	| i < i' = (i,item,s):m:las
>	| otherwise = m : fold_lookahead l las

#else /* not __GLASGOW_HASKELL */

> calcLookaheads
>	:: Int					-- number of states
>	-> [(Int, Lr0Item, Set Name)]		-- spontaneous lookaheads
>	-> Array Int [(Lr0Item, Int, Lr0Item)]	-- propagated lookaheads
>	-> Array Int [(Lr0Item, Set Name)]

> calcLookaheads n_states spont prop
>	= rebuildArray $ fst (mkClosure (\(_,new) _ -> null new) propagate
>	   ([], foldr addLookahead [] spont))
>	where

>         rebuildArray :: [(Int, Lr0Item, Set Name)] -> Array Int [(Lr0Item, Set Name)]
>         rebuildArray xs = array (bounds prop) [ (a,[(b,c)|(a',b,c) <- xs, a==a']) | (a,_,_) <- xs ]

>	  propagate (las,new) = 
>		let
>		   items = [ (i,item'',s) | (j,item,s) <- new, 
>				       (item',i,item'') <- prop ! j,
>				       item == item' ]
>		   new_new = foldr (\i new -> getNew i las new) [] items
>		   new_las = foldr addLookahead las new
>		in
>		(new_las, new_new)

> addLookahead :: (Int,Lr0Item,Set Name) -> [(Int,Lr0Item,Set Name)]
>		-> [(Int,Lr0Item,Set Name)]
> addLookahead l [] = [l]
> addLookahead l@(i,item,s) (m@(i',item',s'):las)
>  	| i == i' && item == item' = (i,item, s `union_Int` s'):las
>	| i < i' = (i,item,s):m:las
>	| otherwise = m : addLookahead l las

> getNew :: (Int,Lr0Item,Set Name) -> [(Int,Lr0Item,Set Name)]
>	-> [(Int,Lr0Item,Set Name)] -> [(Int,Lr0Item,Set Name)]
> getNew l [] new = l:new
> getNew l@(i,item,s) (m@(i',item',s'):las) new
>  	| i == i' && item == item' = 
>		let s'' = filter (`notElem` s') s in
>		if null s'' then new else
>		((i,item,s''):new)
>	| i < i'    = (i,item,s):new
>	| otherwise = getNew l las new

#endif

-----------------------------------------------------------------------------
Merge lookaheads

Stick the lookahead info back into the state table.

> mergeLookaheadInfo
>	:: Array Int [(Lr0Item, Set Name)] 	-- lookahead info
>	-> [(Set Lr0Item, [(Name,Int)])] 	-- state table
>	-> [ ([Lr1Item], [(Name,Int)]) ]

> mergeLookaheadInfo lookaheads sets
>	= zipWith mergeIntoSet sets [0..]
>	where

>	  mergeIntoSet (items, goto) i
>		= (concat (map mergeIntoItem (setToList items)), goto)
>		where

>	  	  mergeIntoItem item@(rule,dot)
>		     = [(rule,dot,la)]
>		     where la = case [ s | (item',s) <- lookaheads ! i,
>					    item == item' ] of
>					[] -> []
>					[x] -> setToList x
>					_ -> error "mergIntoItem"

-----------------------------------------------------------------------------
Generate the goto table

This is pretty straightforward, given all the information we stored
while generating the LR0 sets of items.

Generating the goto table doesn't need lookahead info.

> genGotoTable :: Grammar -> [(Set Lr0Item,[(Name,Int)])] -> GotoTable
> genGotoTable g sets = gotoTable
>   where
>	Grammar{ first_nonterm = fst_nonterm,
>		 first_term    = fst_term,
>		 non_terminals = non_terms } = g
>
>	-- goto array doesn't include %start symbols
>       gotoTable  = listArray (0,length sets-1)
>         [
>           (array (fst_nonterm, fst_term-1) [ 
>		(n, case lookup n goto of
>			Nothing -> NoGoto
>			Just s  -> Goto s)
>                             | n <- non_terms,
>			        n >= fst_nonterm, n < fst_term ])
>                 | (set,goto) <- sets  ]

-----------------------------------------------------------------------------
Generate the action table

> genActionTable :: Grammar -> ([Name] -> Set Name) ->
>		 [([Lr1Item],[(Name,Int)])] -> ActionTable
> genActionTable g first sets = actionTable
>   where
>	Grammar { first_term = fst_term,
>		  terminals = terms,
>		  eof_term = eof,
>		  starts = starts,
>       	  priorities = prios } = g

>	n_starts = length starts
>	isStartRule rule = rule < n_starts -- a bit hacky, but it'll do for now

>       term_lim = (head terms,last terms)
>       actionTable = array (0,length sets-1)
>             [ (set_no, accumArray res
>				 LR'Fail term_lim 
>				(possActions goto set))
>                   | ((set,goto),set_no) <- zip sets [0..] ]

>       possAction goto set (rule,pos,la) = 
>          case findRule g rule pos of
>               Just t | t >= fst_term || t == errorTok -> 
>			case lookup t goto of
>                       	Nothing -> []
>                               Just j  ->
>                                 case lookup t prios of
>                                       Nothing -> [ (t,LR'Shift j{-'-} No) ]
>                                       Just p  -> [ (t,LR'Shift j{-'-} p) ]
>               Nothing
>		   | isStartRule rule -> [ (eof,LR'Accept{-'-}) ]
>                  | otherwise   
>		   -> case lookupProdNo g rule of
>                          (_,_,_,p) -> zip la (repeat (LR'Reduce rule p))
>               _ -> []

>	possActions goto coll = 
>		(concat [ possAction goto coll item |
>				item <- closure1 g first coll ])

These comments are now out of date! /JS

Here's how we resolve conflicts, leaving a complete record of the
conflicting actions in an LR'Multiple structure for later output in
the info file.

Shift/reduce conflicts are always resolved as shift actions, and
reduce/reduce conflicts are resolved as a reduce action using the rule
with the lowest number (i.e. the rule that comes first in the grammar
file.)

NOTES on LR'MustFail: this was introduced as part of the precedence
parsing changes.  The problem with LR'Fail is that it is a soft
failure: we sometimes substitute an LR'Fail for an LR'Reduce (eg. when
computing default actions), on the grounds that an LR'Fail in this
state will also be an LR'Fail in the goto state, so we'll fail
eventually.  This may not be true with precedence parsing, though.  If
there are two non-associative operators together, we must fail at this
point rather than reducing.  Hence the use of LR'MustFail.

>       res LR'Fail x = x
>       res x LR'Fail = x
>	res LR'MustFail x = LR'MustFail
>	res x LR'MustFail = LR'MustFail
>	res x x' | x == x' = x
>	res (LR'Multiple as x) x' = LR'Multiple (x':as) (res x x')
>       res (LR'Accept) _ = LR'Accept
>       res _ (LR'Accept) = LR'Accept
>       res a@(LR'Shift s p) b@(LR'Reduce s' p') = res b a
>       res a@(LR'Reduce s p) b@(LR'Shift s' p')
>		= case (p,p') of
>                      (No,_) -> LR'Multiple [a,b] b
>                      (_,No) -> LR'Multiple [a,b] b
>                      (Prio c i, Prio _ j)
>               		| i < j     -> b
>               		| i > j     -> a
>			        | otherwise ->
>				   case c of
>                                     LeftAssoc  -> a
>                                     RightAssoc -> b
>                                     None       -> LR'MustFail
>       res a@(LR'Reduce r p) b@(LR'Reduce r' p')
>		= case (p,p') of
>                      (No,_) -> LR'Multiple [a,b] b
>                      (_,No) -> LR'Multiple [a,b] b
>                      (Prio c i, Prio _ j)
>               		| i < j     -> b
>               		| j > i     -> a
>				| r < r'    -> LR'Multiple [a,b] a
>				| otherwise -> LR'Multiple [a,b] b
>       res _ _ = error "confict in resolve"

-----------------------------------------------------------------------------
Count the conflicts

> countConflicts :: ActionTable -> (Array Int (Int,Int), (Int,Int))
> countConflicts action
>   = (conflictArray, foldr (\(a,b) (c,d) -> (a+c, b+d)) (0,0) conflictList)
>   
>   where
>	   
>	conflictArray = listArray (bounds action) conflictList
>	conflictList  = map countConflictsState (assocs action)
>
>	countConflictsState (state, actions) 
>	  = foldr countMultiples (0,0) (elems actions)
>	  where
>	    countMultiples (LR'Multiple as a) (sr,rr) 
>	    	= (sr + sr', rr + rr')
>	    	where sr' = foldr (\a b -> case a of
>						LR'Shift _ _ -> 1
>						_ -> b) 0 as
>		      rr' = if (length [ () | (LR'Reduce _ _) <- as ] > 1)
>		      		then 1
>				else 0
>	    countMultiples _ c = c

-----------------------------------------------------------------------------

> findRule :: Grammar -> Int -> Int -> Maybe Name
> findRule g rule dot = 
>	case lookupProdNo g rule of
>	   (_,lhs,_,_) -> case drop dot lhs of
>		            (a:_) -> Just a
>      			    _     -> Nothing
