%-----------------------------------------------------------------------------
LALR.lhs
(c) Andy Gill, Simon Marlow 1993
%-----------------------------------------------------------------------------

> module LALR
> 	(genActionTable, genGotoTable, genLR0items, Lr0Item(..),
>	 propLookaheads, calcLookaheads, mergeLookaheadInfo,
>	 countConflicts,
> 
>	 GrammarInfo(..), Name(..), Set, GotoTable(..),
>	 ActionTable(..)) where

> import GenUtils
> import Set
> import AbsSyn
> import Grammar
> import First

> type Lr0Item = (Int,Int)			-- (rule, dot)
> type Lr1Item = (Int,Int,Name)			-- (rule, dot, lookahead)

> type RuleList = [Lr0Item]

This means rule $a$, with dot at $b$ (all starting at 0)

> startRule :: Set Lr0Item
> startRule = singletonSet (0,0)

%-----------------------------------------------------------------------------
\susbsection{Generating the closure of a set of LR(0) items}

> closure0 :: GrammarInfo -> Set Lr0Item -> Set Lr0Item
> closure0 prod set 
> 	= mkSet (fst (mkClosure (\(_,new) _ -> null new) addRules 
>		([],setToList set)))
>    where

Adding rules to the closure ...  There is a small bug (feature?) in
this algorithm, such that duplicate rules may end up in the final
result, but the iteration is still guaranteed to terminate.  The final
mkSet will get rid of any superfluous rules.

>	addRules :: (RuleList,RuleList) -> (RuleList,RuleList)
>	addRules (oldRules,newRules) 
>		= (newOldRules, newNewRules)
>	   where
>		newOldRules = newRules ++ oldRules
>		newNewRules = filter (`notElem` newOldRules)
>				[ (rule,0) | rule <- concat (map fn newRules) ]
>               fn (rule,dot) = 
>                   case findRule prod rule dot of 
>                       (Just t) | isNT t -> lookupProdsOfName prod t
>                       _                 -> []

%-----------------------------------------------------------------------------
\subsection{Generating the closure of a set of LR(1) items}

> closure1 :: GrammarInfo -> ([Name] -> Set Name) -> Set Lr1Item -> [Lr1Item]
> closure1 gram first set
>       = fst (mkClosure (\(_,new) _ -> null new) addItems ([],setToList set))
>	where

>	addItems :: ([Lr1Item],[Lr1Item]) -> ([Lr1Item],[Lr1Item])
>	addItems (oldItems,newItems) = (newOldItems, newNewItems)
> 	  where
>		newOldItems = newItems ++ oldItems
>		newNewItems = nub (filter (`notElem` newOldItems)
>				(concat (map fn newItems)))

>       	fn (rule,dot,a) = 
>	   	  case lookupProdNo gram rule of
>		   (name,lhs,_) -> 
>		      case drop dot lhs of
>			(b@(NonTerminal nt):beta) ->
>				let terms = setToList (first (beta ++ [a]))
>				    bRules = lookupProdsOfName gram b in
>					[ (rule,0,b) | rule <- bRules,
>						       b <- terms ]
>			_ -> []

%-----------------------------------------------------------------------------
\subsection{goto(I,X) function}

The input should be the closure of a set of kernel items I together with
a token X (terminal or non-terminal.  Output will be the set of kernel
items for the set of items goto(I,X)

> gotoClosure :: GrammarInfo -> Set Lr0Item -> Name -> Set Lr0Item
> gotoClosure gram i x = concatMapSet fn i
>    where
>       fn (rule_no,dot) =
>          case findRule gram rule_no dot of
>               Just t | x == t -> singletonSet (rule_no,dot+1)
>               _ -> emptySet           

%-----------------------------------------------------------------------------
\susbsection{Generating LR0 Item sets}

The item sets are generated in much the same way as we find the
closure of a set of items: we use two sets, those which have already
generated more sets, and those which have just been generated.  We
keep iterating until the second set is empty.

The addItems function is complicated by the fact that we need to keep
information about which sets were generated by which others.

> type ItemSetWithGotos = (Set Lr0Item, [(Name,Int)])

> genLR0items :: GrammarInfo -> [ItemSetWithGotos]
> genLR0items prod
>	= fst (mkClosure (\(old,new) _ -> null new)
>               addItems
>                 (([],[startRule])))
>  where

>    tokens = getNonTerminals prod ++ getTerminals prod

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
>	    (map (\i -> let i' = closure0 prod i in
>	    		[ (x,gotoClosure prod i' x) | x <- tokens ]) newSets)

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

%-----------------------------------------------------------------------------
\susbsection{Computing propagation of lookaheads}

ToDo: generate this info into an array to be used in the subsequent
calcLookaheads pass.

> propLookaheads 
>	:: GrammarInfo
>	-> [(Set Lr0Item,[(Name,Int)])]		-- LR(0) kernel sets
>	-> ([Name] -> Set Name)			-- First function
>	-> (
>		[(Int, Lr0Item, Name)],		-- spontaneous lookaheads
>		Array Int [(Lr0Item, Int, Lr0Item)]	-- propagated lookaheads
>	   )

> propLookaheads gram sets first = (concat s, array (0,length sets - 1) p)
>   where

>     (s,p) = unzip (zipWith propLASet sets [0..])

>     propLASet (set,goto) i = (concat s, i := concat p)
>	where

>	  (s,p) = unzip (map propLAItem (setToList set))

>	  propLAItem item@(rule,dot) = (spontaneous, propagated)
>	    where

>		j = closure1 gram first (singletonSet (rule,dot,dummy))
>		dummy = Terminal 0	-- no such thing as terminal 0, ever.

>		spontaneous = concat [ 
>		 (case findRule gram rule dot of
>		     Nothing -> []
>		     Just x  -> case assocMaybe goto x of
>			 	  Nothing -> error "spontaneous"
>				  Just k  -> [(k, (rule, dot+1), t)])
>			| (rule,dot,t) <- j, t /= Terminal 0 ]

>		propagated = concat [
>		 (case findRule gram rule dot of
>		     Nothing -> []
>		     Just x  -> case assocMaybe goto x of
>				  Nothing -> error "propagated"
>				  Just k  -> [(item, k, (rule, dot+1))])
>			| (rule,dot,Terminal 0) <- j ]

%-----------------------------------------------------------------------------
\subsection{Calculate lookaheads}

ToDo: write this efficiently -- really needs an array with constant
time update.  Use an ordered list for now.

Complexity: monstrous.

> calcLookaheads
>	:: [(Int, Lr0Item, Name)]		-- spontaneous lookaheads
>	-> Array Int [(Lr0Item, Int, Lr0Item)]	-- propagated lookaheads
>	-> [(Int, Lr0Item, Set Name)]

> calcLookaheads spont prop
>	= mkClosure (==) propagate
>	   (foldr addLookahead [] 
>	   	[ (i,item,singletonSet t) | (i,item,t) <- spont])
>	where

>	  propagate las = foldr addLookahead las
>			[ (i,item'',s) | (j,item,s) <- las, 
>				       (item',i,item'') <- prop ! j,
>				       item == item' ]

>	  addLookahead l [] = [l]
>	  addLookahead l@(i,item,s) (m@(i',item',s'):las)
>	  	| i == i' && item == item' = (i,item, s `union` s'):las
>		| i < i' = (i,item,s):m:las
>		| otherwise = m : addLookahead l las

#if 0

Can we do this using a lazy array definition?  Bad news, we have
circular propagations in the lookahead information.  Is there a way to
remove them?

> calcLookaheads'
>	:: [(Int, Lr0Item, Name)]
>	-> Array Int [(Lr0Item, Int, Lr0Item)]
>	-> Array Int [(Lr0Item, Set Name)]

> calcLookaheads' spont prop
>	= result
>	
>	where
>	  result = array (0,top_state) [
>		state :=

Spontaneous Lookaheads

>		[ (item, singletonSet name) | 
>			(st, item, name) <- spont, st == state ] ++

Propagated Lookaheads

>		[ (item, names) |
>			i <- [ 0 .. top_state ],
>			(item', st, item) <- prop ! i,
>			st == state,
>			names <- [ names | (item'', names) <- result ! i,
>					   item'' == item' ] ]
>
>		  | state <- [ 0 .. top_state ] ]
>		  
>	  (_,top_state) = bounds prop

#endif

\subsection{Merge lookaheads}

Stick the lookahead info back into the state table.

> mergeLookaheadInfo
>	:: [(Int, Lr0Item, Set Name)]
>	-> [(Set Lr0Item, [(Name,Int)])]
>	-> [ ([Lr1Item], [(Name,Int)]) ]

> mergeLookaheadInfo lookaheads sets
>	= zipWith mergeIntoSet sets [0..]
>	where

>	  mergeIntoSet (items, goto) i
>		= (concat (map mergeIntoItem (setToList items)), goto)
>		where

>	  	  thisSetLookaheads 
>			= [ l | l@(i',_,_) <- lookaheads, i == i' ]

>	  	  mergeIntoItem item@(rule,dot)
>		     = [(rule,dot,la)
> 			| la <- case [ s | (_,item',s) <- thisSetLookaheads,
>					    item == item' ] of
>					[] -> []
>					[x] -> setToList x
>					_ -> error "mergIntoItem" ]

%-----------------------------------------------------------------------------
\susbsection{Generate the goto table}

This is pretty straightforward, given all the information we stored
while generating the LR0 sets of items.

Generating the goto table doesn't need lookahead info.

> genGotoTable :: GrammarInfo -> [(Set Lr0Item,[(Name,Int)])] -> GotoTable
> genGotoTable gram sets = gotoTable
>   where
>	non_terms = getNonTerminals gram
>       gotoTable = listArray (0,length sets-1)
>         [
>           (array (1, length non_terms-1) [ 
>		(r := case assocMaybe goto nm of
>			Nothing -> NoGoto
>			Just n  -> Goto n)
>                             | nm@(NonTerminal r) <- tail non_terms ])
>                 | (set,goto) <- sets  ]

%-----------------------------------------------------------------------------
\subsectino{Generate the action table}

> genActionTable :: GrammarInfo -> ([Name] -> Set Name) ->
>		 [([Lr1Item],[(Name,Int)])] -> ActionTable
> genActionTable prod first sets = actionTable
>   where
>	terms = getTerminals prod
>	(Terminal eof) = getEOF prod
>       term_lim = (head term_nums,last term_nums)
>       term_nums = [ n | (Terminal n) <- terms ]
>       actionTable = array (0,length sets-1)

>             [ set_no := accumArray res LR'Fail term_lim 
>				(possActions goto set)
>                   | ((set,goto),set_no) <- zip sets [0..] ]

>       possAction goto set (rule,pos,Terminal la) =
>          case findRule prod rule pos of
>               Just t@(Terminal a) -> 
>			case assocMaybe goto t of
>                       	Nothing -> []
>                               Just j  -> [ a := LR'Shift j ]
>               Nothing -> if rule == 0 
>                  then [ eof := LR'Accept ]
>                  else [ la  := LR'Reduce rule ]
>               _ -> []
>	possAction goto set _ = error "possAction"

>	possActions goto coll =
>		concat [ possAction goto coll col | 
>				col <- closure1 prod first (mkSet coll) ]

Here's how we resolve conflicts, leaving a complete record of the
conflicting actions in an LR'Multiple structure for later output in
the info file.

Shift/reduce conflicts are always resolved as shift actions, and
reduce/reduce conflicts are resolved as a reduce action using the rule
with the lowest number (i.e. the rule that comes first in the grammar
file.)

>       res LR'Fail x = x
>       res x LR'Fail = x
>	res x x' | x == x' = x
>	res (LR'Multiple as x) x' = LR'Multiple (x':as) (res x x')
>       res (LR'Accept) _ = LR'Accept
>       res _ (LR'Accept) = LR'Accept
>       res a@(LR'Shift s) b@(LR'Reduce s') = LR'Multiple [a,b] a
>       res a@(LR'Reduce s) b@(LR'Shift s') = LR'Multiple [a,b] b
>	res a@(LR'Reduce r) b@(LR'Reduce r')
>		| r < r'    = LR'Multiple [a,b] a
>		| otherwise = LR'Multiple [a,b] b
>       res _ _ = error "confict in resolve"

%-----------------------------------------------------------------------------
\subsection{Count the conflicts}

> countConflicts :: ActionTable -> (Array Int (Int,Int), (Int,Int))
> countConflicts action
>   = (conflictArray, foldr (\(a,b) (c,d) -> (a+c, b+d)) (0,0) conflictList)
>   
>   where
>	   
>	conflictArray = listArray (bounds action) conflictList
>	conflictList  = map countConflictsState (assocs action)
>
>	countConflictsState (state := actions) 
>	  = foldr countMultiples (0,0) (elems actions)
>	  where
>	    countMultiples (LR'Multiple as a) (sr,rr) 
>	    	= (sr + sr', rr + rr')
>	    	where sr' = foldr (\a b -> case a of
>						LR'Shift _ -> 1
>						_ -> b) 0 as
>		      rr' = if (length [ () | (LR'Reduce _) <- as ] > 1)
>		      		then 1
>				else 0
>	    countMultiples _ c = c

%-----------------------------------------------------------------------------

> findRule :: GrammarInfo -> Int -> Int -> Maybe Name
> findRule prod rule dot = 
>	case lookupProdNo prod rule of
>	   (_,lhs,_) -> case drop dot lhs of
>		         (a:_) -> Just a
>      			 _     -> Nothing


