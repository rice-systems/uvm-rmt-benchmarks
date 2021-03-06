////////////////////////////////////////////////////////////////////////////////////////////////////
// file:	altis\src\cuda\level1\sort\Sort.cu
//
// summary:	Sort class
// 
// origin: SHOC Benchmark (https://github.com/vetter/shoc)
////////////////////////////////////////////////////////////////////////////////////////////////////

#include "OptionParser.h"
#include "ResultDatabase.h"
#include "cudacommon.h"
#include "Sort.h"
#include "sort_kernel.h"
#include <cassert>
#include <cuda.h>
#include <cuda_runtime_api.h>
#include <fstream>
#include <iostream>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <vector>
#include "../uvmdiscard/uvmdiscard.h"

#define SEED 7

using namespace std;

cudaStream_t s_compute;
bool discard = 0;
bool lazy = 0;
int style = 0;
long long bytes;
// ****************************************************************************
// Function: addBenchmarkSpecOptions
//
// Purpose:
//	 Add benchmark specific options parsing
//
// Arguments:
//	 op: the options parser / parameter database
//
// Returns:	nothing
//
// Programmer: Kyle Spafford
// Creation: August 13, 2009
//
// Modifications:
//
// ****************************************************************************
void addBenchmarkSpecOptions(OptionParser &op) {}

// ****************************************************************************
// Function: RunBenchmark
//
// Purpose:
//	 Executes the radix sort benchmark
//
// Arguments:
//	 resultDB: results from the benchmark are stored in this db
//	 op: the options parsefilePathr / parameter database
//
// Returns:	nothing, results are stored in resultDB
//
// Programmer: Kyle Spafford
// Creation: August 13, 2009
//
// Modifications: Bodun Hu
// Add UVM support
//
// ****************************************************************************
void RunBenchmark(ResultDatabase &resultDB, OptionParser &op) {
		cout << "Running Sort" << endl;
	srand(SEED);
	bool quiet = op.getOptionBool("quiet");
	const bool uvm = op.getOptionBool("uvm");
	const bool uvm_prefetch = op.getOptionBool("uvm-prefetch");
	const bool uvm_advise = op.getOptionBool("uvm-advise");
	const bool uvm_prefetch_advise = op.getOptionBool("uvm-prefetch-advise");
	discard = op.getOptionBool("discard");
	lazy = op.getOptionBool("lazy");
	style = op.getOptionInt("style");
	int device = 0;
	checkCudaErrors(cudaGetDevice(&device));

	// Determine size of the array to sort
	size_t size;
	string filePath = op.getOptionString("inputFile");
	ifstream inputFile(filePath.c_str());
	if (filePath == "") {
		if(!quiet) {
				printf("Using problem size %d MB\n", (int)op.getOptionInt("size"));
		}
		// int probSizes[5] = {32, 64, 256, 512, 1024};
		size = op.getOptionInt("size");
		size *= 1024 * 1024;
	} else {
		inputFile >> size;
	}
	bytes = sizeof(uint) * size;
	if(!quiet) {
		printf("Bytes: %lld MB\n", bytes * 4 / 1024 / 1024);
	}

	// If input file given, populate array
	uint *sourceInput = (uint *)malloc(bytes);
	if (filePath != "") {
			for (size_t i = 0; i < size; i++) {
					inputFile >> sourceInput[i];
			}
	}

	// create input data on CPU
	uint *hKeys = NULL;
	uint *hVals = NULL;

	////////////////////////////////////////////////////////////////////////////////////////////////////
	/// <summary>	allocate using UVM API. </summary>
	///
	/// <remarks>	Ed, 5/20/2020. </remarks>
	///
	////////////////////////////////////////////////////////////////////////////////////////////////////

	cudaMallocManaged(&hKeys, bytes);
	cudaMallocManaged(&hVals, bytes);

	// Allocate space for block sums in the scan kernel.
	uint numLevelsAllocated = 0;
	uint maxNumScanElements = size;
	uint numScanElts = maxNumScanElements;
	uint level = 0;

	do {
		uint numBlocks =
				max(1, (int)ceil((float)numScanElts / (4 * SCAN_BLOCK_SIZE)));
		if (numBlocks > 1) {
			level++;
		}
		numScanElts = numBlocks;
	} while (numScanElts > 1);

	uint **scanBlockSums = NULL;
	checkCudaErrors(cudaMallocManaged(&scanBlockSums, (level+1) * sizeof(uint *)));

	numLevelsAllocated = level + 1;
	numScanElts = maxNumScanElements;
	level = 0;

	do {
		uint numBlocks =
				max(1, (int)ceil((float)numScanElts / (4 * SCAN_BLOCK_SIZE)));
		if (numBlocks > 1) {
			// Malloc device mem for block sums
			checkCudaErrors(cudaMallocManaged((void **)&(scanBlockSums[level]),
											numBlocks * sizeof(uint)));
			level++;
		}
		numScanElts = numBlocks;
	} while (numScanElts > 1);

	if (uvm || uvm_advise || uvm_prefetch || uvm_prefetch_advise) {
		checkCudaErrors(cudaMallocManaged((void **)&(scanBlockSums[level]), sizeof(uint)));
	} else {
		checkCudaErrors(cudaMalloc((void **)&(scanBlockSums[level]), sizeof(uint)));
	}

	// Allocate device mem for sorting kernels
	uint *dKeys, *dVals, *dTempKeys, *dTempVals;

	dKeys = hKeys;
	dVals = hVals;
	checkCudaErrors(cudaMallocManaged((void **)&dTempKeys, bytes));
	checkCudaErrors(cudaMallocManaged((void **)&dTempVals, bytes));

	// Each thread in the sort kernel handles 4 elements
	size_t numSortGroups = size / (4 * SORT_BLOCK_SIZE);

	uint *dCounters, *dCounterSums, *dBlockOffsets;
	checkCudaErrors(cudaMallocManaged((void **)&dCounters,
														WARP_SIZE * numSortGroups * sizeof(uint)));
	checkCudaErrors(cudaMallocManaged((void **)&dCounterSums,
														WARP_SIZE * numSortGroups * sizeof(uint)));
	checkCudaErrors(cudaMallocManaged((void **)&dBlockOffsets,
														WARP_SIZE * numSortGroups * sizeof(uint)));

	int iterations = op.getOptionInt("passes");
	cudaStreamCreate(&s_compute);

	printf("Memory consumption: %lu MB\n", bytes * 4 / 1024 / 1024);
	for (int it = 0; it < iterations; it++) {
		// if(!quiet) {
		// 		printf("Pass %d: ", it);
		// }
/// <summary>	Initialize host memory to some pattern. </summary>
		for (size_t i = 0; i < size; i++) {
			hKeys[i] = rand() % (1 << 30);
			if (filePath == "") {
				hVals[i] = rand() % 1024;
			} else {
				hVals[i] = sourceInput[i];
			}
		}

		// Copy inputs to GPU
		double time;
		cudaDeviceSynchronize();
		UvmProbe();
		time = getTime();



        // cudaMemPrefetchAsync(dKeys, bytes, 0, s_compute);
        // cudaMemPrefetchAsync(dVals, bytes, 0, s_compute);
		// Perform Radix Sort (4 bits at a time)
		for (int i = 0; i < SORT_BITS; i += 4) {
			radixSortStep(4, i, (uint4 *)dKeys, (uint4 *)dVals, (uint4 *)dTempKeys,
										(uint4 *)dTempVals, dCounters, dCounterSums, dBlockOffsets,
										scanBlockSums, size);
		}

		cudaDeviceSynchronize();
        time = getTime() - time;
        UvmProbe();

		printf("Runtime: %.2f ms\n", time / 1e6);

		// prefetch or demand paging
		cudaMemPrefetchAsync(dKeys, bytes, cudaCpuDeviceId, s_compute);
		cudaMemPrefetchAsync(dVals, bytes, cudaCpuDeviceId, s_compute);
        cudaDeviceSynchronize();

		// Test to make sure data was sorted properly, if not, return
		if (!verifySort(hKeys, hVals, size, op.getOptionBool("verbose"), op.getOptionBool("quiet"))) {
			return;
		}

		// char atts[1024];
		// sprintf(atts, "%ditems", size);
		// double gb = (bytes * 2.) / (1000. * 1000. * 1000.);
		// resultDB.AddResult("Sort-KernelTime", atts, "sec", time);
	}
	// Clean up
	for (int i = 0; i < numLevelsAllocated; i++) {
		checkCudaErrors(cudaFree(scanBlockSums[i]));
	}
	checkCudaErrors(cudaFree(dKeys));
	checkCudaErrors(cudaFree(dVals));
	checkCudaErrors(cudaFree(dTempKeys));
	checkCudaErrors(cudaFree(dTempVals));
	checkCudaErrors(cudaFree(dCounters));
	checkCudaErrors(cudaFree(dCounterSums));
	checkCudaErrors(cudaFree(dBlockOffsets));

	checkCudaErrors(cudaFree(scanBlockSums));
	free(sourceInput);
}

// ****************************************************************************
// Function: radixSortStep
//
// Purpose:
//	 This function performs a radix sort, using bits startbit to
//	 (startbit + nbits).	It is designed to sort by 4 bits at a time.
//	 It also reorders the data in the values array based on the sort.
//
// Arguments:
//			nbits: the number of key bits to use
//			startbit: the bit to start on, 0 = lsb
//			keys: the input array of keys
//			values: the input array of values
//			tempKeys: temporary storage, same size as keys
//			tempValues: temporary storage, same size as values
//			counters: storage for the index counters, used in sort
//			countersSum: storage for the sum of the counters
//			blockOffsets: storage used in sort
//			scanBlockSums: input to Scan, see below
//			numElements: the number of elements to sort
//
// Returns: nothing
//
// Programmer: Kyle Spafford
// Creation: August 13, 2009
//
// origin: SHOC (https://github.com/vetter/shoc)
//
// ****************************************************************************
void radixSortStep(uint nbits, uint startbit, uint4 *keys, uint4 *values,
									 uint4 *tempKeys, uint4 *tempValues, uint *counters,
									 uint *countersSum, uint *blockOffsets, uint **scanBlockSums,
									 uint numElements) {
	// Threads handle either 4 or two elements each
	const size_t radixGlobalWorkSize = numElements / 4;
	const size_t findGlobalWorkSize = numElements / 2;
	const size_t reorderGlobalWorkSize = numElements / 2;

	// Radix kernel uses block size of 128, others use 256 (same as scan)
	const size_t radixBlocks = radixGlobalWorkSize / SORT_BLOCK_SIZE;
	const size_t findBlocks = findGlobalWorkSize / SCAN_BLOCK_SIZE;
	const size_t reorderBlocks = reorderGlobalWorkSize / SCAN_BLOCK_SIZE;

	// style guide:
	// 0: no prefetch
	// 1: prefetch input buffer
	// 2: prefetch output buffer
	// 3: prefetch proportionally

	printf("Prefetching style is %d, bytes is %lu\n", style, bytes);

	if (discard) {
		UvmDiscardAsync(tempKeys,   bytes, lazy & style, s_compute);
		UvmDiscardAsync(tempValues, bytes, lazy & style, s_compute);
	}

    if (style == 1) {
		cudaMemPrefetchAsync(tempKeys, bytes, 0, s_compute);
		cudaMemPrefetchAsync(tempValues, bytes, 0, s_compute);
    	cudaMemPrefetchAsync(keys, bytes, 0, s_compute);
    	cudaMemPrefetchAsync(values, bytes, 0, s_compute);
    } 

	radixSortBlocks<<<radixBlocks, SORT_BLOCK_SIZE,
										4 * sizeof(uint) * SORT_BLOCK_SIZE, 
										s_compute>>>(
			nbits, startbit, tempKeys, tempValues, keys, values);

	findRadixOffsets<<<findBlocks, SCAN_BLOCK_SIZE,
										 2 * SCAN_BLOCK_SIZE * sizeof(uint),
										 s_compute>>>(
			(uint2 *)tempKeys, counters, blockOffsets, startbit, numElements,
			findBlocks);

	scanArrayRecursive(countersSum, counters, 16 * reorderBlocks, 0,
										 scanBlockSums);

	if (discard) {
		UvmDiscardAsync(keys,   bytes, lazy & style, s_compute);
		UvmDiscardAsync(values, bytes, lazy & style, s_compute);
	}

    if (style == 1) {
    	cudaMemPrefetchAsync(keys, bytes, 0, s_compute);
    	cudaMemPrefetchAsync(values, bytes, 0, s_compute);
		cudaMemPrefetchAsync(tempKeys, bytes, 0, s_compute);
		cudaMemPrefetchAsync(tempValues, bytes, 0, s_compute);
    } 

	reorderData<<<reorderBlocks, SCAN_BLOCK_SIZE, 0, s_compute>>>(
			startbit, (uint *)keys, (uint *)values, (uint2 *)tempKeys,
			(uint2 *)tempValues, blockOffsets, countersSum, counters, reorderBlocks);
}

////////////////////////////////////////////////////////////////////////////////////////////////////
/// <summary>	Perform scan op on input array recursively. </summary>
///
/// <remarks>	Ed, 5/19/2020. </remarks>
///
/// <param name="outArray">	 	[in,out] If non-null, array of outs. </param>
/// <param name="inArray">			[in,out] If non-null, array of INS. </param>
/// <param name="numElements">	Number of elements. </param>
/// <param name="level">			The num of levels. </param>
/// <param name="blockSums">		[in,out] The block sum array. </param>
////////////////////////////////////////////////////////////////////////////////////////////////////

void scanArrayRecursive(uint *outArray, uint *inArray, int numElements,
												int level, uint **blockSums) {
	// Kernels handle 8 elems per thread
	unsigned int numBlocks =
			max(1, (unsigned int)ceil((float)numElements / (4.f * SCAN_BLOCK_SIZE)));
	unsigned int sharedEltsPerBlock = SCAN_BLOCK_SIZE * 2;
	unsigned int sharedMemSize = sizeof(uint) * sharedEltsPerBlock;

	bool fullBlock = (numElements == numBlocks * 4 * SCAN_BLOCK_SIZE);

	dim3 grid(numBlocks, 1, 1);
	dim3 threads(SCAN_BLOCK_SIZE, 1, 1);

	// execute the scan
	if (numBlocks > 1) {
		scan<<<grid, threads, sharedMemSize, s_compute>>>(outArray, inArray, blockSums[level],
																					 numElements, fullBlock, true);
	} else {
		scan<<<grid, threads, sharedMemSize, s_compute>>>(outArray, inArray, blockSums[level],
																					 numElements, fullBlock, false);
	}
	if (numBlocks > 1) {
		scanArrayRecursive(blockSums[level], blockSums[level], numBlocks, level + 1,
											 blockSums);
		vectorAddUniform4<<<grid, threads, 0, s_compute>>>(outArray, blockSums[level],
																				 numElements);
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////
/// <summary>	Verify the correctness of sort on cpu. </summary>
///
/// <remarks>	Kyle Spafford, 8/13/2009
/// 			Ed, 5/19/2020. </remarks>
///
/// <param name="keys">	 	[in,out] If non-null, the keys. </param>
/// <param name="vals">	 	[in,out] If non-null, the vals. </param>
/// <param name="size">	 	The size. </param>
/// <param name="verbose">	True to verbose. </param>
/// <param name="quiet">		True to quiet. </param>
///
/// <returns>	True if it succeeds, false if it fails. </returns>
////////////////////////////////////////////////////////////////////////////////////////////////////

bool verifySort(uint *keys, uint *vals, const size_t size, bool verbose, bool quiet) {
	bool passed = true;
	for (size_t i = 0; i < size - 1; i++) {
		if (keys[i] > keys[i + 1]) {
			passed = false;
			// if(verbose && !quiet)	{
			cout << "Failure: at idx: " << i << endl;
			cout << "Key: " << keys[i] << " Val: " << vals[i] << endl;
			cout << "Idx: " << i + 1 << " Key: " << keys[i + 1]
					<< " Val: " << vals[i + 1] << endl;
			// }
			break;
		}
	}
	if (!quiet) {
			cout << "Test ";
			if (passed) {
					cout << "Passed" << endl;
			} else {
					cout << "Failed" << endl;
			}
	}
	return passed;
}
