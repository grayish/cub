
/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::DeviceReduce provides operations for computing a device-wide, parallel reduction across data items residing within global memory.
 */

#pragma once

#include <stdio.h>
#include <iterator>

#include "block/block_reduce_tiles.cuh"
#include "../thread/thread_operators.cuh"
#include "../grid/grid_even_share.cuh"
#include "../grid/grid_queue.cuh"
#include "../util_debug.cuh"
#include "../util_device.cuh"
#include "../util_namespace.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {

#ifndef DOXYGEN_SHOULD_SKIP_THIS    // Do not document






/******************************************************************************
 * Kernel entry points
 *****************************************************************************/

/**
 * Reduce tiles kernel entry point (multi-block).  Computes privatized reductions, one per thread block.
 */
template <
    typename                BlockReduceTilesPolicy, ///< Tuning policy for cub::BlockReduceTiles abstraction
    typename                InputIterator,          ///< Random-access iterator type for input (may be a simple pointer type)
    typename                OutputIterator,         ///< Random-access iterator type for output (may be a simple pointer type)
    typename                SizeT,                  ///< Integer type used for global array indexing
    typename                ReductionOp>            ///< Binary reduction operator type having member <tt>T operator()(const T &a, const T &b)</tt>
__launch_bounds__ (int(BlockReduceTilesPolicy::BLOCK_THREADS), 1)
__global__ void ReduceTilesKernel(
    InputIterator           d_in,                   ///< [in] Input data to reduce
    OutputIterator          d_out,                  ///< [out] Output location for result
    SizeT                   num_items,              ///< [in] Total number of input data items
    GridEvenShare<SizeT>    even_share,             ///< [in] Even-share descriptor for mapping an equal number of tiles onto each thread block
    GridQueue<SizeT>        queue,                  ///< [in] Drain queue descriptor for dynamically mapping tile data onto thread blocks
    ReductionOp             reduction_op)           ///< [in] Binary reduction operator
{
    // Data type
    typedef typename std::iterator_traits<InputIterator>::value_type T;

    // Thread block type for reducing input tiles
    typedef BlockReduceTiles<BlockReduceTilesPolicy, InputIterator, SizeT, ReductionOp> BlockReduceTilesT;

    // Block-wide aggregate
    T block_aggregate;

    // Shared memory storage
    __shared__ typename BlockReduceTilesT::TempStorage temp_storage;

    // Consume input tiles
    BlockReduceTilesT(temp_storage, d_in, reduction_op).ConsumeTiles(
        num_items,
        even_share,
        queue,
        block_aggregate,
        Int2Type<BlockReduceTilesPolicy::GRID_MAPPING>());

    // Output result
    if (threadIdx.x == 0)
    {
        d_out[blockIdx.x] = block_aggregate;
    }
}


/**
 * Reduce a single tile kernel entry point (single-block).  Can be used to aggregate privatized threadblock reductions from a previous multi-block reduction pass.
 */
template <
    typename                BlockReduceTilesPolicy, ///< Tuning policy for cub::BlockReduceTiles abstraction
    typename                InputIterator,          ///< Random-access iterator type for input (may be a simple pointer type)
    typename                OutputIterator,         ///< Random-access iterator type for output (may be a simple pointer type)
    typename                SizeT,                  ///< Integer type used for global array indexing
    typename                ReductionOp>            ///< Binary reduction operator type having member <tt>T operator()(const T &a, const T &b)</tt>
__launch_bounds__ (int(BlockReduceTilesPolicy::BLOCK_THREADS), 1)
__global__ void SingleTileKernel(
    InputIterator           d_in,                   ///< [in] Input data to reduce
    OutputIterator          d_out,                  ///< [out] Output location for result
    SizeT                   num_items,              ///< [in] Total number of input data items
    ReductionOp             reduction_op)           ///< [in] Binary reduction operator
{
    // Data type
    typedef typename std::iterator_traits<InputIterator>::value_type T;

    // Thread block type for reducing input tiles
    typedef BlockReduceTiles<BlockReduceTilesPolicy, InputIterator, SizeT, ReductionOp> BlockReduceTilesT;

    // Block-wide aggregate
    T block_aggregate;

    // Shared memory storage
    __shared__ typename BlockReduceTilesT::TempStorage temp_storage;

    // Consume input tiles
    BlockReduceTilesT(temp_storage, d_in, reduction_op).ConsumeTiles(
        SizeT(0),
        SizeT(num_items),
        block_aggregate);

    // Output result
    if (threadIdx.x == 0)
    {
        d_out[blockIdx.x] = block_aggregate;
    }
}




/******************************************************************************
 * Dispatch
 ******************************************************************************/

/**
 * Utility class for dispatching the appropriately-tuned kernels for DeviceReduce
 */
template <
    typename InputIterator,     ///< Random-access iterator type for input (may be a simple pointer type)
    typename OutputIterator,    ///< Random-access iterator type for output (may be a simple pointer type)
    typename SizeT,             ///< Integer type used for global array indexing
    typename ReductionOp>       ///< Binary reduction operator type having member <tt>T operator()(const T &a, const T &b)</tt>
struct DeviceReduceDispatch
{
    // Data type of input iterator
    typedef typename std::iterator_traits<InputIterator>::value_type T;


    /******************************************************************************
     * Tuning policies
     ******************************************************************************/

    /// SM35
    struct Policy350
    {
        // ReduceTilesPolicy1B (GTX Titan: 206.0 GB/s @ 192M 1B items)
        typedef BlockReduceTilesPolicy<
                128,                                ///< Threads per thread block
                12,                                 ///< Items per thread per tile of input
                1,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_LDG,                           ///< PTX load modifier
                GRID_MAPPING_DYNAMIC>               ///< How to map tiles of input onto thread blocks
            ReduceTilesPolicy1B;

        // ReduceTilesPolicy4B (GTX Titan: 254.2 GB/s @ 48M 4B items)
        typedef BlockReduceTilesPolicy<
                512,                                ///< Threads per thread block
                20,                                 ///< Items per thread per tile of input
                1,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            ReduceTilesPolicy4B;

        // ReduceTilesPolicy
        typedef typename If<(sizeof(T) < 4),
            ReduceTilesPolicy1B,
            ReduceTilesPolicy4B>::Type ReduceTilesPolicy;

        // SingleTilePolicy
        typedef BlockReduceTilesPolicy<
                256,                                ///< Threads per thread block
                8,                                  ///< Items per thread per tile of input
                1,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_WARP_REDUCTIONS,       ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            SingleTilePolicy;
    };

    /// SM30
    struct Policy300
    {
        // ReduceTilesPolicy (GTX670: 154.0 @ 48M 4B items)
        typedef BlockReduceTilesPolicy<
                256,                                ///< Threads per thread block
                2,                                  ///< Items per thread per tile of input
                1,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_WARP_REDUCTIONS,       ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            ReduceTilesPolicy;

        // SingleTilePolicy
        typedef BlockReduceTilesPolicy<
                256,                                ///< Threads per thread block
                24,                                 ///< Items per thread per tile of input
                4,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_WARP_REDUCTIONS,       ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            SingleTilePolicy;
    };

    /// SM20
    struct Policy200
    {
        // ReduceTilesPolicy1B (GTX 580: 158.1 GB/s @ 192M 1B items)
        typedef BlockReduceTilesPolicy<
                192,                                ///< Threads per thread block
                24,                                 ///< Items per thread per tile of input
                4,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            ReduceTilesPolicy1B;

        // ReduceTilesPolicy4B (GTX 580: 178.9 GB/s @ 48M 4B items)
        typedef BlockReduceTilesPolicy<
                128,                                ///< Threads per thread block
                8,                                  ///< Items per thread per tile of input
                4,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_DYNAMIC>               ///< How to map tiles of input onto thread blocks
            ReduceTilesPolicy4B;

        // ReduceTilesPolicy
        typedef typename If<(sizeof(T) < 4),
            ReduceTilesPolicy1B,
            ReduceTilesPolicy4B>::Type ReduceTilesPolicy;

        // SingleTilePolicy
        typedef BlockReduceTilesPolicy<
                192,                                ///< Threads per thread block
                7,                                  ///< Items per thread per tile of input
                1,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            SingleTilePolicy;
    };

    /// SM13
    struct Policy130
    {
        // ReduceTilesPolicy
        typedef BlockReduceTilesPolicy<
                128,                                ///< Threads per thread block
                8,                                  ///< Items per thread per tile of input
                2,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            ReduceTilesPolicy;

        // SingleTilePolicy
        typedef BlockReduceTilesPolicy<
                32,                                 ///< Threads per thread block
                4,                                  ///< Items per thread per tile of input
                4,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            SingleTilePolicy;
    };

    /// SM10
    struct Policy100
    {
        // ReduceTilesPolicy
        typedef BlockReduceTilesPolicy<
                128,                                ///< Threads per thread block
                8,                                  ///< Items per thread per tile of input
                2,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            ReduceTilesPolicy;

        // SingleTilePolicy
        typedef BlockReduceTilesPolicy<
                32,                                 ///< Threads per thread block
                4,                                  ///< Items per thread per tile of input
                4,                                  ///< Number of items per vectorized load
                BLOCK_REDUCE_RAKING,                ///< Cooperative block-wide reduction algorithm to use
                LOAD_DEFAULT,                       ///< PTX load modifier
                GRID_MAPPING_EVEN_SHARE>            ///< How to map tiles of input onto thread blocks
            SingleTilePolicy;
    };


    /******************************************************************************
     * Tuning policies of current PTX compiler pass
     ******************************************************************************/

#if (CUB_PTX_VERSION >= 350)
    typedef Policy350 PtxPolicy;

#elif (CUB_PTX_VERSION >= 300)
    typedef Policy300 PtxPolicy;

#elif (CUB_PTX_VERSION >= 200)
    typedef Policy200 PtxPolicy;

#elif (CUB_PTX_VERSION >= 130)
    typedef Policy130 PtxPolicy;

#else
    typedef Policy100 PtxPolicy;

#endif

    // "Opaque" policies (whose parameterizations aren't reflected in the type signature)
    struct ReduceTilesPolicy    : PtxPolicy::ReduceTilesPolicy {};
    struct SingleTilePolicy     : PtxPolicy::SingleTilePolicy {};


    /**
     * Kernel dispatch configuration
     */
    struct KernelDispatchConfig
    {
        int                     block_threads;
        int                     items_per_thread;
        int                     vector_load_length;
        BlockReduceAlgorithm    block_algorithm;
        PtxLoadModifier         load_modifier;
        GridMappingStrategy     grid_mapping;

        template <typename BlockPolicy>
        __host__ __device__ __forceinline__
        void Init()
        {
            block_threads               = BlockPolicy::BLOCK_THREADS;
            items_per_thread            = BlockPolicy::ITEMS_PER_THREAD;
            vector_load_length          = BlockPolicy::VECTOR_LOAD_LENGTH;
            block_algorithm             = BlockPolicy::BLOCK_ALGORITHM;
            load_modifier               = BlockPolicy::LOAD_MODIFIER;
            grid_mapping                = BlockPolicy::GRID_MAPPING;
        }

        __host__ __device__ __forceinline__
        void Print()
        {
            printf("%d threads, %d per thread, %d veclen, %d algo, %d loadmod, %d mapping",
                block_threads,
                items_per_thread,
                vector_load_length,
                block_algorithm,
                load_modifier,
                grid_mapping);
        }
    };


    /******************************************************************************
     * Utilities
     ******************************************************************************/

    /**
     * Initialize dispatch configurations with the policies corresponding to the PTX assembly we will use
     */
    template <typename KernelDispatchConfig>
    __host__ __device__ __forceinline__
    static void InitDispatchConfigs(
        int                     ptx_version,
        KernelDispatchConfig    &reduce_tiles_config,
        KernelDispatchConfig    &single_tile_config)
    {
    #ifdef __CUDA_ARCH__

        // We're on the device, so initialize the dispatch configurations with the PtxDefaultPolicies directly
        reduce_tiles_config.Init<ReduceTilesPolicy>();
        single_tile_config.Init<SingleTilePolicy>();

    #else

        // We're on the host, so lookup and initialize the dispatch configurations with the policies that match the device's PTX version
        if (ptx_version >= 350)
        {
            reduce_tiles_config.template    Init<typename Policy350::ReduceTilesPolicy>();
            single_tile_config.template     Init<typename Policy350::SingleTilePolicy>();
        }
        else if (ptx_version >= 300)
        {
            reduce_tiles_config.template    Init<typename Policy300::ReduceTilesPolicy>();
            single_tile_config.template     Init<typename Policy300::SingleTilePolicy>();
        }
        else if (ptx_version >= 200)
        {
            reduce_tiles_config.template    Init<typename Policy200::ReduceTilesPolicy>();
            single_tile_config.template     Init<typename Policy200::SingleTilePolicy>();
        }
        else if (ptx_version >= 130)
        {
            reduce_tiles_config.template    Init<typename Policy130::ReduceTilesPolicy>();
            single_tile_config.template     Init<typename Policy130::SingleTilePolicy>();
        }
        else
        {
            reduce_tiles_config.template    Init<typename Policy100::ReduceTilesPolicy>();
            single_tile_config.template     Init<typename Policy100::SingleTilePolicy>();
        }

    #endif
    }


    /******************************************************************************
     * Dispatch entrypoints
     ******************************************************************************/

    /**
     * Internal dispatch routine for computing a device-wide reduction using the
     * specified kernel functions.
     *
     * If the input is larger than a single tile, this method uses two-passes of
     * kernel invocations.
     */
    template <
        typename                    ReduceTilesKernelPtr,               ///< Function type of cub::ReduceTilesKernel
        typename                    AggregateTileKernelPtr,             ///< Function type of cub::SingleTileKernel for consuming partial reductions (T*)
        typename                    SingleTileKernelPtr,                ///< Function type of cub::SingleTileKernel for consuming input (InputIterator)
        typename                    FillAndResetDrainKernelPtr>         ///< Function type of cub::FillAndResetDrainKernel
    __host__ __device__ __forceinline__
    static cudaError_t Dispatch(
        void                        *d_temp_storage,                    ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,                ///< [in,out] Size in bytes of \p d_temp_storage allocation.
        InputIterator               d_in,                               ///< [in] Input data to reduce
        OutputIterator              d_out,                              ///< [out] Output location for result
        SizeT                       num_items,                          ///< [in] Number of items to reduce
        ReductionOp                 reduction_op,                       ///< [in] Binary reduction operator
        cudaStream_t                stream,                             ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous,                  ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Also causes launch configurations to be printed to the console.  Default is \p false.
        int                         sm_version,                         ///< [in] SM version of target device to use when computing SM occupancy
        FillAndResetDrainKernelPtr  prepare_drain_kernel,               ///< [in] Kernel function pointer to parameterization of cub::FillAndResetDrainKernel
        ReduceTilesKernelPtr        reduce_tiles_kernel,                ///< [in] Kernel function pointer to parameterization of cub::ReduceTilesKernel
        AggregateTileKernelPtr      aggregate_kernel,                   ///< [in] Kernel function pointer to parameterization of cub::SingleTileKernel for consuming partial reductions (T*)
        SingleTileKernelPtr         single_kernel,                      ///< [in] Kernel function pointer to parameterization of cub::SingleTileKernel for consuming input (InputIterator)
        KernelDispatchConfig        &reduce_tiles_config,               ///< [in] Dispatch parameters that match the policy that \p reduce_tiles_kernel_ptr was compiled for
        KernelDispatchConfig        &single_tile_config)                ///< [in] Dispatch parameters that match the policy that \p single_kernel was compiled for
    {
#ifndef CUB_RUNTIME_ENABLED

        // Kernel launch not supported from this device
        return CubDebug(cudaErrorNotSupported );

#else

        cudaError error = cudaSuccess;
        do
        {
            // Tile size of reduce_tiles_kernel
            int tile_size = reduce_tiles_config.block_threads * reduce_tiles_config.items_per_thread;

            if ((reduce_tiles_kernel == NULL) || (num_items <= tile_size))
            {
                // Dispatch a single-block reduction kernel

                // Return if the caller is simply requesting the size of the storage allocation
                if (d_temp_storage == NULL)
                {
                    temp_storage_bytes = 1;
                    return cudaSuccess;
                }

                // Log single_kernel configuration
                if (debug_synchronous) CubLog("Invoking ReduceSingle<<<1, %d, 0, %lld>>>(), %d items per thread\n",
                    single_tile_config.block_threads, (long long) stream, single_tile_config.items_per_thread);

                // Invoke single_kernel
                single_kernel<<<1, single_tile_config.block_threads>>>(
                    d_in,
                    d_out,
                    num_items,
                    reduction_op);

                // Sync the stream if specified
                if (debug_synchronous && (CubDebug(error = SyncStream(stream)))) break;

            }
            else
            {
                // Dispatch two kernels: (1) a multi-block kernel to compute
                // privatized per-block reductions, and (2) a single-block
                // to reduce those partial reductions

                // Get device ordinal
                int device_ordinal;
                if (CubDebug(error = cudaGetDevice(&device_ordinal))) break;

                // Get SM count
                int sm_count;
                if (CubDebug(error = cudaDeviceGetAttribute (&sm_count, cudaDevAttrMultiProcessorCount, device_ordinal))) break;

                // Get SM occupancy for histogram_tiles_kernel
                int reduce_tiles_sm_occupancy;
                if (CubDebug(error = MaxSmOccupancy(
                    reduce_tiles_sm_occupancy,
                    sm_version,
                    reduce_tiles_kernel,
                    reduce_tiles_config.block_threads))) break;

                // Get device occupancy for histogram_tiles_kernel
                int reduce_tiles_occupancy = reduce_tiles_sm_occupancy * sm_count;

                // Even-share work distribution
                int subscription_factor = reduce_tiles_sm_occupancy;     // Amount of CTAs to oversubscribe the device beyond actively-resident (heuristic)
                GridEvenShare<SizeT> even_share(
                    num_items,
                    reduce_tiles_occupancy * subscription_factor,
                    tile_size);

                // Get grid size for reduce_tiles_kernel
                int reduce_tiles_grid_size;
                switch (reduce_tiles_config.grid_mapping)
                {
                case GRID_MAPPING_EVEN_SHARE:

                    // Work is distributed evenly
                    reduce_tiles_grid_size = even_share.grid_size;
                    break;

                case GRID_MAPPING_DYNAMIC:

                    // Work is distributed dynamically
                    int num_tiles = (num_items + tile_size - 1) / tile_size;
                    reduce_tiles_grid_size = (num_tiles < reduce_tiles_occupancy) ?
                        num_tiles :                     // Not enough to fill the device with threadblocks
                        reduce_tiles_occupancy;         // Fill the device with threadblocks
                    break;
                };

                // Temporary storage allocation requirements
                void* allocations[2];
                size_t allocation_sizes[2] =
                {
                    reduce_tiles_grid_size * sizeof(T),     // bytes needed for privatized block reductions
                    GridQueue<int>::AllocationSize()        // bytes needed for grid queue descriptor
                };

                // Alias the temporary allocations from the single storage blob (or set the necessary size of the blob)
                if (CubDebug(error = AliasTemporaries(d_temp_storage, temp_storage_bytes, allocations, allocation_sizes))) break;
                if (d_temp_storage == NULL)
                {
                    // Return if the caller is simply requesting the size of the storage allocation
                    return cudaSuccess;
                }

                // Alias the allocation for the privatized per-block reductions
                T *d_block_reductions = (T*) allocations[0];

                // Alias the allocation for the grid queue descriptor
                GridQueue<SizeT> queue(allocations[1]);

                // Prepare the dynamic queue descriptor if necessary
                if (reduce_tiles_config.grid_mapping == GRID_MAPPING_DYNAMIC)
                {
                    // Prepare queue using a kernel so we know it gets prepared once per operation
                    if (debug_synchronous) CubLog("Invoking prepare_drain_kernel<<<1, 1, 0, %lld>>>()\n", (long long) stream);

                    // Invoke prepare_drain_kernel
                    prepare_drain_kernel<<<1, 1, 0, stream>>>(queue, num_items);

                    // Sync the stream if specified
                    if (debug_synchronous && (CubDebug(error = SyncStream(stream)))) break;
                }

                // Log reduce_tiles_kernel configuration
                if (debug_synchronous) CubLog("Invoking reduce_tiles_kernel<<<%d, %d, 0, %lld>>>(), %d items per thread, %d SM occupancy\n",
                    reduce_tiles_grid_size, reduce_tiles_config.block_threads, (long long) stream, reduce_tiles_config.items_per_thread, reduce_tiles_sm_occupancy);

                // Invoke reduce_tiles_kernel
                reduce_tiles_kernel<<<reduce_tiles_grid_size, reduce_tiles_config.block_threads, 0, stream>>>(
                    d_in,
                    d_block_reductions,
                    num_items,
                    even_share,
                    queue,
                    reduction_op);

                // Sync the stream if specified
                if (debug_synchronous && (CubDebug(error = SyncStream(stream)))) break;

                // Log single_kernel configuration
                if (debug_synchronous) CubLog("Invoking single_kernel<<<%d, %d, 0, %lld>>>(), %d items per thread\n",
                    1, single_tile_config.block_threads, (long long) stream, single_tile_config.items_per_thread);

                // Invoke single_kernel
                aggregate_kernel<<<1, single_tile_config.block_threads, 0, stream>>>(
                    d_block_reductions,
                    d_out,
                    reduce_tiles_grid_size,
                    reduction_op);

                // Sync the stream if specified
                if (debug_synchronous && (CubDebug(error = SyncStream(stream)))) break;
            }
        }
        while (0);

        return error;

#endif // CUB_RUNTIME_ENABLED
    }


    /**
     * Internal dispatch routine for computing a device-wide reduction
     */
    __host__ __device__ __forceinline__
    static cudaError_t Dispatch(
        void                        *d_temp_storage,                    ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,                ///< [in,out] Size in bytes of \p d_temp_storage allocation.
        InputIterator               d_in,                               ///< [in] Input data to reduce
        OutputIterator              d_out,                              ///< [out] Output location for result
        SizeT                       num_items,                          ///< [in] Number of items to reduce
        ReductionOp                 reduction_op,                       ///< [in] Binary reduction operator
        cudaStream_t                stream,                             ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous)                  ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Also causes launch configurations to be printed to the console.  Default is \p false.
    {
        cudaError error = cudaSuccess;
        do
        {
            // Get PTX version
            int ptx_version;
    #ifndef __CUDA_ARCH__
            if (CubDebug(error = PtxVersion(ptx_version))) break;
    #else
            ptx_version = CUB_PTX_VERSION;
    #endif

            // Get kernel dispatch configurations
            KernelDispatchConfig reduce_tiles_config;
            KernelDispatchConfig single_tile_config;
            InitDispatchConfigs(ptx_version, reduce_tiles_config, single_tile_config);

            // Dispatch
            if (CubDebug(error = Dispatch(
                d_temp_storage,
                temp_storage_bytes,
                d_in,
                d_out,
                num_items,
                reduction_op,
                stream,
                debug_synchronous,
                ptx_version,            // Use PTX version instead of SM version because, as a statically known quantity, this improves device-side launch dramatically but at the risk of imprecise occupancy calculation for mismatches
                FillAndResetDrainKernel<SizeT>,
                ReduceTilesKernel<ReduceTilesPolicy, InputIterator, T*, SizeT, ReductionOp>,
                SingleTileKernel<SingleTilePolicy, T*, OutputIterator, SizeT, ReductionOp>,
                SingleTileKernel<SingleTilePolicy, InputIterator, OutputIterator, SizeT, ReductionOp>,
                reduce_tiles_config,
                single_tile_config))) break;
        }
        while (0);

        return error;
    }
};


#endif // DOXYGEN_SHOULD_SKIP_THIS



/******************************************************************************
 * DeviceReduce
 *****************************************************************************/

/**
 * \brief DeviceReduce provides operations for computing a device-wide, parallel reduction across data items residing within global memory. ![](reduce_logo.png)
 * \ingroup DeviceModule
 *
 * \par Overview
 * A <a href="http://en.wikipedia.org/wiki/Reduce_(higher-order_function)"><em>reduction</em></a> (or <em>fold</em>)
 * uses a binary combining operator to compute a single aggregate from a list of input elements.
 *
 * \par Usage Considerations
 * \cdp_class{DeviceReduce}
 *
 * \par Performance
 *
 * \image html reduction_perf.png
 *
 */
struct DeviceReduce
{
    /**
     * \brief Computes a device-wide reduction using the specified binary \p reduction_op functor.
     *
     * \par
     * Does not support non-commutative reduction operators.
     *
     * \devicestorage
     *
     * \cdp
     *
     * \iterator
     *
     * \par
     * The code snippet below illustrates the max reduction of a device vector of \p int items.
     * \par
     * \code
     * #include <cub/cub.cuh>
     * ...
     *
     * // Declare and initialize device pointers for input and output
     * int *d_reduce_input, *d_aggregate;
     * int num_items = ...
     * ...
     *
     * // Determine temporary device storage requirements for reduction
     * void *d_temp_storage = NULL;
     * size_t temp_storage_bytes = 0;
     * cub::DeviceReduce::Reduce(d_temp_storage, temp_storage_bytes, d_reduce_input, d_aggregate, num_items, cub::Max());
     *
     * // Allocate temporary storage for reduction
     * cudaMalloc(&d_temp_storage, temp_storage_bytes);
     *
     * // Run reduction (max)
     * cub::DeviceReduce::Reduce(d_temp_storage, temp_storage_bytes, d_reduce_input, d_aggregate, num_items, cub::Max());
     *
     * \endcode
     *
     * \tparam InputIterator      <b>[inferred]</b> Random-access iterator type for input (may be a simple pointer type)
     * \tparam OutputIterator     <b>[inferred]</b> Random-access iterator type for output (may be a simple pointer type)
     * \tparam ReductionOp          <b>[inferred]</b> Binary reduction operator type having member <tt>T operator()(const T &a, const T &b)</tt>
     */
    template <
        typename                    InputIterator,
        typename                    OutputIterator,
        typename                    ReductionOp>
    __host__ __device__ __forceinline__
    static cudaError_t Reduce(
        void                        *d_temp_storage,                    ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,                ///< [in,out] Size in bytes of \p d_temp_storage allocation.
        InputIterator               d_in,                               ///< [in] Input data to reduce
        OutputIterator              d_out,                              ///< [out] Output location for result
        int                         num_items,                          ///< [in] Number of items to reduce
        ReductionOp                 reduction_op,                       ///< [in] Binary reduction operator
        cudaStream_t                stream              = 0,            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous  = false)         ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Also causes launch configurations to be printed to the console.  Default is \p false.
    {
        typedef int SizeT;
        return DeviceReduceDispatch<InputIterator, OutputIterator, SizeT, ReductionOp>::Dispatch(
            d_temp_storage, temp_storage_bytes, d_in, d_out, num_items, reduction_op, stream, debug_synchronous);
    }


    /**
     * \brief Computes a device-wide sum using the addition ('+') operator.
     *
     * \par
     * Does not support non-commutative reduction operators.
     *
     * \devicestorage
     *
     * \cdp
     *
     * \iterator
     *
     * \par
     * The code snippet below illustrates the sum reduction of a device vector of \p int items.
     * \par
     * \code
     * #include <cub/cub.cuh>
     * ...
     *
     * // Declare and initialize device pointers for input and output
     * int *d_reduce_input, *d_aggregate;
     * int num_items = ...
     * ...
     *
     * // Determine temporary device storage requirements for summation
     * void *d_temp_storage = NULL;
     * size_t temp_storage_bytes = 0;
     * cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes, d_reduce_input, d_aggregate, num_items);
     *
     * // Allocate temporary storage for summation
     * cudaMalloc(&d_temp_storage, temp_storage_bytes);
     *
     * // Run reduction summation
     * cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes, d_reduce_input, d_aggregate, num_items);
     *
     * \endcode
     *
     * \tparam InputIterator      <b>[inferred]</b> Random-access iterator type for input (may be a simple pointer type)
     * \tparam OutputIterator     <b>[inferred]</b> Random-access iterator type for output (may be a simple pointer type)
     */
    template <
        typename                    InputIterator,
        typename                    OutputIterator>
    __host__ __device__ __forceinline__
    static cudaError_t Sum(
        void                        *d_temp_storage,                    ///< [in] %Device allocation of temporary storage.  When NULL, the required allocation size is returned in \p temp_storage_bytes and no work is done.
        size_t                      &temp_storage_bytes,                ///< [in,out] Size in bytes of \p d_temp_storage allocation.
        InputIterator               d_in,                               ///< [in] Input data to reduce
        OutputIterator              d_out,                              ///< [out] Output location for result
        int                         num_items,                          ///< [in] Number of items to reduce
        cudaStream_t                stream              = 0,            ///< [in] <b>[optional]</b> CUDA stream to launch kernels within.  Default is stream<sub>0</sub>.
        bool                        debug_synchronous  = false)         ///< [in] <b>[optional]</b> Whether or not to synchronize the stream after every kernel launch to check for errors.  Also causes launch configurations to be printed to the console.  Default is \p false.
    {
        typedef int SizeT;
        return DeviceReduceDispatch<InputIterator, OutputIterator, SizeT, cub::Sum>::Dispatch(
            d_temp_storage, temp_storage_bytes, d_in, d_out, num_items, cub::Sum(), stream, debug_synchronous);
    }


};


}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)


