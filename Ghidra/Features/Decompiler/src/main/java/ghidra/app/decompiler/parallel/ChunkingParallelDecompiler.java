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

import java.util.*;

import generic.concurrent.*;
import ghidra.app.util.DecompilerConcurrentQ;
import ghidra.program.model.listing.Function;
import ghidra.util.task.TaskMonitor;

/**
 * A class that simplifies some the concurrent datastructure setup required for decompiling 
 * functions.  This class is meant to be used when you wish to decompile functions in groups 
 * (or chunks) rather than decompiling all functions at once.
 *
 * @param <R> The result type
 */
public class ChunkingParallelDecompiler<R> implements AutoCloseable {

	private DecompilerConcurrentQ<Function, R> queue;

	ChunkingParallelDecompiler(QCallback<Function, R> callback, TaskMonitor monitor) {
		queue =
			new DecompilerConcurrentQ<Function, R>(callback, ParallelDecompiler.THREAD_POOL_NAME,
				monitor);
	}

	ChunkingParallelDecompiler(QCallback<Function, R> callback, int maxInProgress,
			TaskMonitor monitor) {
		if (maxInProgress <= 0) {
			throw new IllegalArgumentException("maxInProgress must be positive");
		}
		queue = new DecompilerConcurrentQ<>(callback,
			GThreadPool.getSharedThreadPool(ParallelDecompiler.THREAD_POOL_NAME), true,
			maxInProgress, monitor);
	}

	public List<R> decompileFunctions(List<Function> functions) throws InterruptedException,
			Exception {

		queue.addAll(functions);

		Collection<QResult<Function, R>> qResults = queue.waitForResults();

		List<R> results = new ArrayList<R>();
		for (QResult<Function, R> qResult : qResults) {
			results.add(qResult.getResult());
		}

		return results;
	}

	public void dispose() {
		queue.dispose();
	}

	/**
	 * Disposes the queue. The caller still owns the callback and must dispose a
	 * {@link DecompilerCallback} after all its work has stopped.
	 */
	@Override
	public void close() {
		dispose();
	}
}
