
-- | Thread pool implementation.
module Development.Shake.Pool(Pool, addPool, blockPool, runPool) where

import Control.Concurrent
import Control.Exception hiding (blocked)
import Development.Shake.Locks
import qualified Data.HashSet as Set
import Data.Maybe


---------------------------------------------------------------------
-- RANDOM QUEUE

-- Monad for non-deterministic (but otherwise pure) computations
type NonDet a = IO a

data RandomQueue a = RandomQueue [a] [a]

newRandomQueue :: RandomQueue a
newRandomQueue = RandomQueue [] []

enqueuePriority :: a -> RandomQueue a -> RandomQueue a
enqueuePriority x (RandomQueue p n) = RandomQueue (x:p) n

enqueue :: a -> RandomQueue a -> NonDet (RandomQueue a)
enqueue x (RandomQueue p n) = return $ RandomQueue p (x:n)

dequeue :: RandomQueue a -> Maybe (NonDet (a, RandomQueue a))
dequeue (RandomQueue (p:ps) ns) = Just $ return (p, RandomQueue ps ns)
dequeue (RandomQueue [] (n:ns)) = Just $ return (n, RandomQueue [] ns)
dequeue (RandomQueue [] []) = Nothing


---------------------------------------------------------------------
-- THREAD POOL

{-
Must keep a list of active threads, so can raise exceptions in a timely manner
Must spawn a fresh thread to do blockPool
If any worker throws an exception, must signal to all the other workers
-}

data Pool = Pool Int (Var (Maybe S)) (Barrier (Maybe SomeException))

data S = S
    {threads :: Set.HashSet ThreadId
    ,working :: Int -- threads which are actively working
    ,blocked :: Int -- threads which are blocked
    ,todo :: RandomQueue (IO ())
    }


emptyS :: S
emptyS = S Set.empty 0 0 newRandomQueue


-- | Given a pool, and a function that breaks the S invariants, restore them
--   They are only allowed to touch working or todo
step :: Pool -> (S -> NonDet S) -> IO ()
step pool@(Pool n var done) op = do
    let onVar act = modifyVar_ var $ maybe (return Nothing) act
    onVar $ \s -> do
        s <- op s
        res <- maybe (return Nothing) (fmap Just) $ dequeue $ todo s
        case res of
            Just (now, todo2) | working s < n -> do
                -- spawn a new worker
                t <- forkIO $ do
                    t <- myThreadId
                    res <- try now
                    case res of
                        Left e -> onVar $ \s -> do
                            mapM_ killThread $ Set.toList $ Set.delete t $ threads s
                            signalBarrier done $ Just e
                            return Nothing
                        Right _ -> step pool $ \s -> return s{working = working s - 1, threads = Set.delete t $ threads s}
                return $ Just s{working = working s + 1, todo = todo2, threads = Set.insert t $ threads s}
            Nothing | working s == 0 && blocked s == 0 -> do
                signalBarrier done Nothing
                return Nothing
            _ -> return $ Just s


-- | Add a new task to the pool
addPool :: Pool -> IO a -> IO ()
addPool pool act = step pool $ \s -> do
    todo <- enqueue (act >> return ()) (todo s)
    return s{todo = todo}


-- | A blocking action is being run while on the pool, yeild your thread.
--   Should only be called by an action under addPool.
blockPool :: Pool -> IO a -> IO a
blockPool pool act = do
    step pool $ \s -> return s{working = working s - 1, blocked = blocked s + 1}
    res <- act
    var <- newBarrier
    let act = do
            step pool $ \s -> return s{working = working s + 1, blocked = blocked s - 1}
            signalBarrier var ()
    step pool $ \s -> return s{todo = enqueuePriority act $ todo s}
    waitBarrier var
    return res


-- | Run all the tasks in the pool on the given number of works.
--   If any thread throws an exception, the exception will be reraised.
runPool :: Int -> (Pool -> IO ()) -> IO () -- run all tasks in the pool
runPool n act = do
    s <- newVar $ Just emptyS
    let cleanup = modifyVar_ s $ \s -> do
            -- if someone kills our thread, make sure we kill our child threads
            case s of
                Just s -> mapM_ killThread $ Set.toList $ threads s
                Nothing -> return ()
            return Nothing
    flip onException cleanup $ do
        res <- newBarrier
        let pool = Pool n s res
        addPool pool $ act pool
        res <- waitBarrier res
        case res of
            Nothing -> return ()
            Just e -> throw e
