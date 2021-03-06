{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PackageImports #-}
module Main
    where 

import Control.Concurrent.Async
import Control.Monad
import System.Environment

import qualified Data.Primitive as P
import Control.Concurrent
import Control.Concurrent.Chan
import Control.Concurrent.STM
import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM.TBQueue

import Control.Concurrent.MVar
import Data.IORef
import Criterion.Main
import Control.Exception(evaluate)


import qualified "chan-split-fast" Control.Concurrent.Chan.Split as S
import qualified "split-channel" Control.Concurrent.Chan.Split as SC
import Data.Primitive.MutVar
import Control.Monad.Primitive(PrimState)
import Data.Atomics.Counter
import Data.Atomics

#if MIN_VERSION_base(4,7,0)
#else
import qualified Data.Concurrent.Queue.MichaelScott as MS
#endif

import GHC.Conc

import Benchmarks

-- These tests initially taken from stm/bench/chanbench.hs, ported to
-- criterion, with some additions.
--
-- The original used CPP to avoid code duplication while also ensuring GHC
-- optimized the code in a realistic fashion. Here we just copy paste.

main = do 
  let n = 100000
--let n = 2000000  -- original suggested value, bugs if exceeded

  procs <- getNumCapabilities
  let procs_div2 = procs `div` 2
  if procs_div2 >= 0 then return ()
                     else error "Run with RTS +N2 or more"

  mv <- newEmptyMVar -- This to be left empty after each test
  mvFull <- newMVar undefined
  -- --
  -- mvWithFinalizer <- newEmptyMVar
  -- mkWeakMVar mvWithFinalizer $ return ()
  -- --
  -- mvFinalizee <- newMVar 'a'
  -- mvWithFinalizer <- newMVar ()
  -- mkWeakMVar mvWithFinalizer $
  --     modifyMVar_ mvFinalizee (const $ return 'b')
  -- --
  tmv <- newEmptyTMVarIO 
  tv <- newTVarIO undefined 
  ior <- newIORef undefined
  mutv <- newMutVar undefined

  counter_mvar <- newMVar (1::Int)
  counter_ioref <- newIORef (1::Int)
  counter_tvar <- newTVarIO (1::Int)
  counter_atomic_counter <- newCounter (1::Int)

  fill_empty_chan <- newChan
  fill_empty_tchan <- newTChanIO
  fill_empty_tqueue <- newTQueueIO
  fill_empty_tbqueue <- newTBQueueIO maxBound
  (fill_empty_fastI, fill_empty_fastO) <- S.newSplitChan
  (fill_empty_splitchannelI, fill_empty_splitchannelO) <- SC.new
#if MIN_VERSION_base(4,7,0)
#else
  fill_empty_lockfree <- MS.newQ
#endif

  defaultMain $
        [ bgroup "Var primitives" $
            -- This gives us an idea of how long a lock is held by these atomic
            -- ops, and the effects of retry/blocking scheduling behavior.
            -- compare this with latency measure in Main1 to get the whole
            -- picture:
            -- Subtract the cost of:
            --   - 2 context switches
            --   - 4 newEmptyMVar
            --   - 4 takeMVar
            --   - 4 putMVar
            -- TODO: also test with N green threads per core.
            [ bgroup ("Throughput on "++(show n)++" concurrent atomic mods") $
                -- just forks some threads all atomically modifying a variable:
                let {-# INLINE mod_test #-}
                    mod_test = mod_test_n n
                    {-# INLINE mod_test_n #-}
                    mod_test_n n' = \threads modf -> do
                      dones <- replicateM threads newEmptyMVar ; starts <- replicateM threads newEmptyMVar
                      mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n' `div` threads) modf >> putMVar done1 ()) $ zip starts dones
                      mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones

                    -- We use this payload to scale contention; on my machine
                    -- timesN values of 1,2,3,4 run at fairly consistent: 15ns,
                    -- 19ns, 29ns, and 37ns (note: 22.4ns for an atomicModifyIORef)
                    {-# NOINLINE payload #-}
                    payload timesN = (evaluate $ (foldr ($) 2 $ replicate timesN sqrt) :: IO Float)

                    varGroupPayload perProc numPL = [
                         bench "modifyMVar_" $ mod_test (procs*perProc) $
                          (modifyMVar_ counter_mvar (return . (+1)) >> payload numPL)

                        , bench "modifyMVarMasked_" $ mod_test (procs*perProc) $
                            (modifyMVarMasked_ counter_mvar (return . (+1)) >> payload numPL)
                        
                        , bench "atomicModifyIORef'" $ mod_test (procs*perProc) $
                            (atomicModifyIORef' counter_ioref (\x-> (x+1,()) ) >> payload numPL)

                        , bench "atomically modifyTVar'" $ mod_test (procs*perProc) $
                            ((atomically $ modifyTVar' counter_tvar ((+1))) >> payload numPL) 

                        , bench "incrCounter (atomic-primops)" $ mod_test (procs*perProc) $
                            (incrCounter 1 counter_atomic_counter >> payload numPL)
                        
                        , bench "atomicModifyIORefCAS (atomic-primops)" $ mod_test (procs*perProc) $
                            (atomicModifyIORefCAS counter_ioref (\x-> (x+1,()) ) >> payload numPL)

                        , bench "atomicModifyIORefCAS' (my CAS loop)" $ mod_test (procs*perProc) $
                            (atomicModifyIORefCAS' counter_ioref (\x-> (x+1,()) ) >> payload numPL)

                        ]

                 in [ bgroup "1 thread per HEC, full contention" $
                       [ bench "modifyMVar_" $ mod_test procs $
                          (modifyMVar_ counter_mvar (return . (+1)))

                        , bench "modifyMVarMasked_" $ mod_test procs $
                            (modifyMVarMasked_ counter_mvar (return . (+1)))
                        
                        , bench "atomicModifyIORef'" $ mod_test procs $
                            (atomicModifyIORef' counter_ioref (\x-> (x+1,()) ))

                        , bench "atomically modifyTVar'" $ mod_test procs $
                            (atomically $ modifyTVar' counter_tvar ((+1))) 

                        , bench "incrCounter (atomic-primops)" $ mod_test procs $
                            (incrCounter 1 counter_atomic_counter)
                        
                        , bench "atomicModifyIORefCAS (atomic-primops)" $ mod_test procs $
                            (atomicModifyIORefCAS counter_ioref (\x-> (x+1,()) ))
                        
                        , bench "atomicModifyIORefCAS' (my CAS loop)" $ mod_test procs $
                            (atomicModifyIORefCAS' counter_ioref (\x-> (x+1,()) ))
                        
                        -- I want to compare these with the same results above;
                        -- see also TVarExperiment:
                        -- , bench "atomicModifyIORef' x10" $ mod_test_n (10*n) procs $
                        --     (atomicModifyIORef' counter_ioref (\x-> (x+1,()) ))
                        -- , bench "atomically modifyTVar' x10" $ mod_test_n (10*n) procs $
                        --     (atomically $ modifyTVar' counter_tvar ((+1))) 
                        ]
                    , bgroup "2 threads per HEC, full contention" $
                       [ bench "modifyMVar_" $ mod_test (procs*2) $
                          (modifyMVar_ counter_mvar (return . (+1)))

                        , bench "modifyMVarMasked_" $ mod_test (procs*2) $
                            (modifyMVarMasked_ counter_mvar (return . (+1)))
                        
                        -- WTF! This is suddenly giving me a stack overflow....
                        -- , bench "atomicModifyIORef'" $ mod_test (procs*2) $
                        --     (atomicModifyIORef' counter_ioref (\x-> (x+1,()) ))

                        , bench "atomically modifyTVar'" $ mod_test (procs*2) $
                            (atomically $ modifyTVar' counter_tvar ((+1))) 

                        , bench "incrCounter (atomic-primops)" $ mod_test (procs*2) $
                            (incrCounter 1 counter_atomic_counter)
                        
                        , bench "atomicModifyIORefCAS (atomic-primops)" $ mod_test (procs*2) $
                            (atomicModifyIORefCAS counter_ioref (\x-> (x+1,()) ))

                        ]
                   
                   {- COMMENTING, since the atomicModifyIORef' below is *again*
                      causing stack overflow for no apparent reason TODO why?

                    -- NOTE: adding more threads per-HEC at this point shows
                    -- little difference (very bad MVar locking behavior has
                    -- mostly disappeared)
                    --
                    -- test dialing back the contention:
                    , bgroup "1 threads per HEC, 1 payload" $ 
                        varGroupPayload 1 1
                    , bgroup "1 threads per HEC, 2 payload" $
                        varGroupPayload 1 2
                    , bgroup "1 threads per HEC, 4 payload" $
                        varGroupPayload 1 4
                    , bgroup "1 threads per HEC, 8 payload" $
                        varGroupPayload 1 8

                    -- this is an attempt to see if a somewhat random delay can
                    -- get rid of (some or all) the very slow runs; hypothesis
                    -- being that those runs get into some bad harmonics and
                    -- contention is slow to resolve.
                    , bgroup "1 thread per HEC, scattered payloads with IORefs" $
                        let benchRandPayloadIORef evry pyld = 
                                bench ("atomicModifyIORef' "++(show evry)++" "++(show pyld)) $ 
                                  mod_test procs $
                                    (atomicModifyIORef' counter_ioref (\x-> (x+1,x) ) 
                                     >>= \x-> if x `mod` evry == 0 then payload pyld else return 1)
                         in [ benchRandPayloadIORef 2 1
                            , benchRandPayloadIORef 2 4
                            , benchRandPayloadIORef 2 16
                            , benchRandPayloadIORef 8 1
                            , benchRandPayloadIORef 8 4
                            , benchRandPayloadIORef 8 16
                            , benchRandPayloadIORef 32 1
                            , benchRandPayloadIORef 32 4
                            , benchRandPayloadIORef 32 16
                            ]

                    , bgroup "Test Payload" $
                        [ bench "payload x1" $ payload 1
                        , bench "payload x2" $ payload 2
                        , bench "payload x4" $ payload 4
                        , bench "payload x8" $ payload 8
                        ]
                     -}
                    ]
            , bgroup "Misc" $
                -- If the second shows some benefit on just two threads, then 
                -- it represents a useful technique for reducing contention:
                [ bench "contentious atomic-maybe-modify IORef" $ atomicMaybeModifyIORef n
                , bench "read first, then maybe contentious atomic-maybe-modify IORef" $ readMaybeAtomicModifyIORef n
                , bench "readForCAS, then CAS (atomic-primops)" $ readMaybeCAS n
              -- NOT RELEVANT:
                -- , bench "Higher contention, contentious atomic-maybe-modify IORef" $ atomicMaybeModifyIORefHiC n
                -- , bench "Higher contention, read first, then maybe contentious atomic-maybe-modify IORef" $ readMaybeAtomicModifyIORefHiC n
                , bench "contentious atomic-maybe-modify TVar" $ atomicMaybeModifyTVar n
                , bench "read first, then maybe contentious atomic-maybe-modify TVar" $ readMaybeAtomicModifyTVar n

                -- we should expect these to be the same:
                , bench "reads against atomicModifyIORefs" $ readsAgainstAtomicModifyIORefs n
                , bench "reads against modifyIORefs" $ readsAgainstNonAtomicModify n
                -- TODO how do these compare with STM?
                ]
            ]
            -- TODO: define these in terms of numCapabilities:
            -- 1 r thread 1 w thread: measuring r/w contention
            -- 2 w threads ONLY: meeasure w/w contention, THEN:
            -- 2 r threads ONLY: meeasure r/r contention
            -- more threads: measuring descheduling bottlenecks, context switching overheads (+ above)
            --    above better tested outside criterion, w/ eventlogging
            --    also test equivalents of above on 8-core
        , bgroup "Channel implementations" $
            [ bgroup ("Operations on "++(show n)++" messages") $
                [ bgroup "For scale" $
                      -- For TQueue style chans, test the cost of reverse
                      [ bench "reverse [1..n]" $ nf (\n'-> reverse [1..n']) n
                      , bench "reverse replicate n 1" $ nf (\n'-> replicate n' (1::Int)) n
                      ]
                , bgroup "Chan" $
                      -- this gives us a measure of effects of contention between
                      -- readers and writers when compared with single-threaded
                      -- version:
                      [ bench "async 1 writer 1 readers" $ runtestChanAsync 1 1 n
                      -- NOTE: this is a bit hackish, filling in one test and
                      -- reading in the other; make sure memory usage isn't
                      -- influencing mean:
                      --
                      -- This measures writer/writer contention, in this case I
                      -- think we see a lot of thread blocking/waiting delays
                      , bench ("async "++(show procs)++" writers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (writeChan fill_empty_chan ()) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      -- This measures reader/reader contention:
                      , bench ("async "++(show procs)++" readers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (readChan fill_empty_chan) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      -- This is measuring the effects of bottlenecks caused by
                      -- descheduling, context-switching overhead (forced my
                      -- fairness properties in the case of MVar), as well as
                      -- all of the above; this is probably less than
                      -- informative. Try threadscope on a standalone test:
                      , bench "contention: async 100 writers 100 readers" $ runtestChanAsync 100 100 n
                      ]
                , bgroup "TChan" $
                      [ bench "async 1 writers 1 readers" $ runtestTChanAsync 1 1 n
                      -- This measures writer/writer contention:
                      {- LIVELOCK!!!
                      , bench ("async "++(show procs)++" writers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (atomically $ writeTChan fill_empty_tchan ()) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      -- This measures reader/reader contention:
                      , bench ("async "++(show procs)++" readers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (atomically $ readTChan fill_empty_tchan) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      , bench "contention: async 100 writers 100 readers" $ runtestTChanAsync 100 100 n
                      -}
                      ]
                , bgroup "TQueue" $
                      [ bench "async 1 writers 1 readers" $ runtestTQueueAsync 1 1 n
                      -- This measures writer/writer contention:
                      , bench ("async "++(show procs)++" writers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (atomically $ writeTQueue fill_empty_tqueue ()) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      -- This measures reader/reader contention:
                      , bench ("async "++(show procs)++" readers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (atomically $ readTQueue fill_empty_tqueue) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      , bench "contention: async 100 writers 100 readers" $ runtestTQueueAsync 100 100 n
                      ]
                , bgroup "TBQueue" $
                      [ bench "async 1 writers 1 readers" $ runtestTBQueueAsync 1 1 n
                      -- This measures writer/writer contention:
                      , bench ("async "++(show procs)++" writers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (atomically $ writeTBQueue fill_empty_tbqueue ()) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      -- This measures reader/reader contention:
                      , bench ("async "++(show procs)++" readers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (atomically $ readTBQueue fill_empty_tbqueue) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      , bench "contention: async 100 writers 100 readers" $ runtestTBQueueAsync 100 100 n
                      ]
                -- OTHER CHAN IMPLEMENTATIONS:
                , bgroup "chan-split-fast" $
                      [ bench "async 1 writers 1 readers" $ runtestSplitChanAsync 1 1 n
                      -- This measures writer/writer contention:
                      , bench ("async "++(show procs)++" writers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (S.writeChan fill_empty_fastI ()) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      -- This measures reader/reader contention:
                      , bench ("async "++(show procs)++" readers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (S.readChan fill_empty_fastO) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      , bench "contention: async 100 writers 100 readers" $ runtestSplitChanAsync 100 100 n
                      ]
                , bgroup "split-channel" $
                      [ bench "async 1 writers 1 readers" $ runtestSplitChannelAsync 1 1 n
                      -- This measures writer/writer contention:
                      , bench ("async "++(show procs)++" writers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (SC.send fill_empty_splitchannelI ()) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      -- This measures reader/reader contention:
                      , bench ("async "++(show procs)++" readers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (SC.receive fill_empty_splitchannelO) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      , bench "contention: async 100 writers 100 readers" $ runtestSplitChannelAsync 100 100 n
                      ]
                -- michael-scott queue implementation, using atomic-primops
#if MIN_VERSION_base(4,7,0)
#else
                , bgroup "lockfree-queue" $
                      [ bench "async 1 writer 1 readers" $ runtestLockfreeQueueAsync 1 1 n
                      , bench ("async "++(show procs)++" writers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (MS.pushL fill_empty_lockfree ()) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      , bench ("async "++(show procs)++" readers") $ do
                          dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
                          mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (msreadR fill_empty_lockfree) >> putMVar done1 ()) $ zip starts dones
                          mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
                      , bench "contention: async 100 writers 100 readers" $ runtestLockfreeQueueAsync 100 100 n
                      ]
#endif
                -- Chase / Lev work-stealing queue
                -- NOTE: we can have at most 1 writer (pushL); not a general-purpose queue, so don't do more tests
                , bgroup "chaselev-dequeue" $
                      [ bench "async 1 writer 1 readers" $ runtestChaseLevQueueAsync_1_1 n
                      ]
                ]
            ]
        , bgroup "Arrays misc" $
            -- be sure to subtract "cost" of 2 forkIO's and context switch
            [ bench "baseline" $
                do x <- newEmptyMVar
                   y <- newEmptyMVar
                   forkIO $ (replicateM_ 500 $ return ()) >> putMVar x ()
                   forkIO $ (replicateM_ 500 $ return ()) >> putMVar y ()
                   takeMVar x
                   takeMVar y
            , bench "New 32-length MutableArrays x1000 across two threads" $
                do x <- newEmptyMVar
                   y <- newEmptyMVar
                   forkIO $ (replicateM_ 500 $ (P.newArray 32 0 :: IO (P.MutableArray (PrimState IO) Int))) >> putMVar x ()
                   forkIO $ (replicateM_ 500 $ (P.newArray 32 0 :: IO (P.MutableArray (PrimState IO) Int))) >> putMVar y ()
                   takeMVar x
                   takeMVar y
            , bench "New MVar x1000 across two threads" $
                do x <- newEmptyMVar
                   y <- newEmptyMVar
                   forkIO $ (replicateM_ 500 $ (newEmptyMVar :: IO (MVar Int))) >> putMVar x ()
                   forkIO $ (replicateM_ 500 $ (newEmptyMVar :: IO (MVar Int))) >> putMVar y ()
                   takeMVar x
                   takeMVar y
            ]
        ]
  -- to make sure the counter is actually being incremented!:
  cntv <- readCounter counter_atomic_counter
  putStrLn $ "Final counter val is "++(show cntv)
