/* ###
 * IP: GHIDRA
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package ghidra.app.decompiler.parallel;

import static org.junit.Assert.*;

import java.util.Collections;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;

import generic.concurrent.GThreadPool;
import ghidra.app.util.DecompilerConcurrentQ;
import ghidra.util.task.TaskMonitor;
import ghidra.util.task.TaskMonitorAdapter;

public class ChunkingParallelDecompilerTest {

	@Test(timeout = 10000)
	public void testBoundedRepeatedChunks() throws Exception {
		AtomicInteger active = new AtomicInteger();
		AtomicInteger maximum = new AtomicInteger();
		CountDownLatch started = new CountDownLatch(2);
		CountDownLatch release = new CountDownLatch(1);
		ExecutorService caller = Executors.newSingleThreadExecutor();
		try (ChunkingParallelDecompiler<Integer> decompiler =
			ParallelDecompiler.createChunkingParallelDecompiler((function, monitor) -> {
				int count = active.incrementAndGet();
				maximum.accumulateAndGet(count, Math::max);
				started.countDown();
				try {
					assertTrue(release.await(5, TimeUnit.SECONDS));
					return 1;
				}
				finally {
					active.decrementAndGet();
				}
			}, 2, TaskMonitor.DUMMY)) {
			Future<Integer> first = caller.submit(() ->
				decompiler.decompileFunctions(Collections.nCopies(20, null)).size());
			assertTrue(started.await(5, TimeUnit.SECONDS));
			assertEquals(2, active.get());
			release.countDown();
			assertEquals(20, first.get(5, TimeUnit.SECONDS).intValue());
			assertEquals(20,
				decompiler.decompileFunctions(Collections.nCopies(20, null)).size());
			assertEquals(2, maximum.get());
		}
		finally {
			release.countDown();
			caller.shutdownNow();
		}
	}

	@Test
	public void testLimitDoesNotChangeSharedPoolOrLegacyFactory() throws Exception {
		GThreadPool pool = GThreadPool.getSharedThreadPool(ParallelDecompiler.THREAD_POOL_NAME);
		int originalLimit = pool.getMaxThreadCount();
		try (ChunkingParallelDecompiler<Integer> decompiler =
			ParallelDecompiler.createChunkingParallelDecompiler((f, m) -> 1, 1,
				TaskMonitor.DUMMY)) {
			assertEquals(Collections.singletonList(1),
				decompiler.decompileFunctions(Collections.singletonList(null)));
			assertEquals(originalLimit, pool.getMaxThreadCount());
		}
		try (ChunkingParallelDecompiler<Integer> legacy =
			ParallelDecompiler.createChunkingParallelDecompiler((f, m) -> 2,
				TaskMonitor.DUMMY)) {
			assertEquals(Collections.singletonList(2),
				legacy.decompileFunctions(Collections.singletonList(null)));
		}
	}

	@Test
	public void testCallbackFailureReachesCallerAndNextChunkWorks() throws Exception {
		AtomicInteger calls = new AtomicInteger();
		IllegalStateException failure = new IllegalStateException("callback failure");
		try (ChunkingParallelDecompiler<Integer> decompiler =
			ParallelDecompiler.createChunkingParallelDecompiler((f, m) -> {
				if (calls.getAndIncrement() == 0) {
					throw failure;
				}
				return 1;
			}, 1, TaskMonitor.DUMMY)) {
			try {
				decompiler.decompileFunctions(Collections.singletonList(null));
				fail("Expected the callback failure");
			}
			catch (ExecutionException expected) {
				assertSame(failure, expected.getCause());
			}
			assertEquals(Collections.singletonList(1),
				decompiler.decompileFunctions(Collections.singletonList(null)));
		}
	}

	@Test(timeout = 10000)
	public void testCancellationStopsQueuedWork() throws Exception {
		TaskMonitorAdapter monitor = new TaskMonitorAdapter(true);
		CountDownLatch started = new CountDownLatch(1);
		CountDownLatch exited = new CountDownLatch(1);
		CountDownLatch release = new CountDownLatch(1);
		AtomicInteger calls = new AtomicInteger();
		ExecutorService caller = Executors.newSingleThreadExecutor();
		try (ChunkingParallelDecompiler<Integer> decompiler =
			ParallelDecompiler.createChunkingParallelDecompiler((f, m) -> {
				calls.incrementAndGet();
				started.countDown();
				try {
					release.await();
					return 1;
				}
				finally {
					exited.countDown();
				}
			}, 1, monitor)) {
			Future<?> result = caller.submit(() ->
				decompiler.decompileFunctions(Collections.nCopies(20, null)));
			assertTrue(started.await(5, TimeUnit.SECONDS));
			monitor.cancel();
			result.get(5, TimeUnit.SECONDS);
			assertTrue(exited.await(5, TimeUnit.SECONDS));
			assertEquals(1, calls.get());
		}
		finally {
			release.countDown();
			caller.shutdownNow();
		}
	}

	@Test
	public void testRejectsNonpositiveLimit() {
		for (int limit : new int[] { 0, -1 }) {
			try {
				ParallelDecompiler.createChunkingParallelDecompiler((f, m) -> 1, limit,
					TaskMonitor.DUMMY);
				fail("Expected a positive worker limit");
			}
			catch (IllegalArgumentException expected) {
				// expected
			}
		}
	}

	@Test(timeout = 10000)
	public void testDirectQueueLimitContract() throws Exception {
		GThreadPool pool = GThreadPool.getPrivateThreadPool("decompiler-queue-limit-test");
		pool.setMaxThreadCount(2);
		CountDownLatch started = new CountDownLatch(2);
		CountDownLatch release = new CountDownLatch(1);
		AtomicInteger active = new AtomicInteger();
		AtomicInteger maximum = new AtomicInteger();
		DecompilerConcurrentQ<Integer, Integer> queue = new DecompilerConcurrentQ<>((item, monitor) -> {
			maximum.accumulateAndGet(active.incrementAndGet(), Math::max);
			started.countDown();
			try {
				assertTrue(release.await(5, TimeUnit.SECONDS));
				return item;
			}
			finally {
				active.decrementAndGet();
			}
		}, pool, true, 0, TaskMonitor.DUMMY);
		try {
			queue.addAll(Collections.nCopies(10, 1));
			assertTrue(started.await(5, TimeUnit.SECONDS));
			assertEquals(2, active.get());
			release.countDown();
			assertEquals(10, queue.waitForResults().size());
			assertEquals(2, maximum.get());
			assertEquals(2, pool.getMaxThreadCount());
			try {
				new DecompilerConcurrentQ<>((item, monitor) -> item, pool, true, -1,
					TaskMonitor.DUMMY);
				fail("Expected a nonnegative queue limit");
			}
			catch (IllegalArgumentException expected) {
				// expected
			}
		}
		finally {
			release.countDown();
			queue.dispose();
			pool.shutdownNow();
		}
	}
}
