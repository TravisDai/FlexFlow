/* Copyright 2019 Stanford
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "model.h"
#include "cuda_helper.h"
#include <math.h>
#include <stdio.h>

#define MAX_K 2
#define MAX_BATCH_SIZE 64
#define MAX_N 10


void FFModel::group_by(const Tensor& input,
                        const Tensor& assign,
                        Tensor* outputs,
                        int n, float alpha,
                        const char* name)
{
  GroupBy* group_by = new GroupBy(*this, input, assign, n, alpha, name);
  layers.push_back(group_by);
  for (int i = 0; i < n; i++)
    outputs[i] = group_by->outputs[i];
}


GroupBy::GroupBy(FFModel& model,
                  const Tensor& _input,
                  const Tensor& _assign,
                  int _n, float _alpha,
                  const char* name)
: Op(model, OP_GROUP_BY, name, _input, _assign),
  n(_n),
  alpha(_alpha),
  profiling(model.config.profiling)
{
  // FIXME: For now, set upper limits Better: Do as follows, but memory is
  // assigned per block, so requires to check that
  // https://stackoverflow.com/questions/5531247/allocating-shared-memory/5531640#5531640
  assert(n <= MAX_N && "Increase MAX_N in #define");
  assert(inputs[1].adim[0] <= MAX_K && "Increase MAX_K in #define");
  assert(inputs[0].adim[1] <= MAX_BATCH_SIZE && "Increase MAX_BATCH_SIZE in #define");

  int num_dim = _input.numDim;
  assert(_assign.numDim == 2);
  assert(_input.adim[num_dim-1] == _assign.adim[1]);
  assert(n > 0);

  // output dims
  int k = _assign.adim[0];
  int batch_size = inputs[1].adim[1];
  for(int i = 0; i < n; i++) {
    outputs[i].numDim = num_dim;
    for(int j = 0; j < num_dim-1; j++) {
      outputs[i].adim[j] = inputs[0].adim[j];
    }
    outputs[i].adim[num_dim-1] = (int)ceil(alpha*k/n*batch_size);
  }

  numWeights = 0;
}


void GroupBy::create_weights(FFModel& model)
{
  // Do nothing
}

template<int NDIM>
void GroupBy::create_output_and_partition_with_dim(FFModel& model)
{
  // Retrieve the task indexspace for the op
  std::string pcname = name;
  task_is = IndexSpaceT<NDIM>(model.get_or_create_task_is(NDIM, pcname));
  Context ctx = model.config.lg_ctx;
  Runtime* runtime = model.config.lg_hlr;
  Rect<NDIM> part_rect = runtime->get_index_space_domain(ctx, task_is);

  // Can only partition over the sample dim
  assert(part_rect.hi[0] == part_rect.lo[0]);

  int k = inputs[1].adim[0];
  int dims[NDIM];
  dims[0] = (int)ceil(alpha*k/n*inputs[1].adim[1]);
  for(int i = 1; i < NDIM; i++) {
    dims[i] = inputs[0].adim[NDIM-i-1];
  }
  for(int i = 0; i < n; i++) {
    outputs[i] = model.create_tensor<NDIM>(dims, inputs[0].data_type, this);
    outputs[i].owner_op = this;
    outputs[i].owner_idx = i;
  }

  // Compute partition bound for input
  model.create_data_parallel_partition_with_diff_dims<2, NDIM>(
      inputs[1], (IndexSpaceT<NDIM>)task_is, input_lps[1], input_grad_lps[1]);
  Rect<NDIM> input_rect = runtime->get_index_partition_color_space(
      ctx, inputs[0].part.get_index_partition());
  if (input_rect == part_rect) {
    input_lps[0] = inputs[0].part;
    input_grad_lps[0] = inputs[0].part_grad;
  } else {
    model.create_disjoint_partition<NDIM>(
      inputs[0], (IndexSpaceT<NDIM>)task_is, input_lps[0], input_grad_lps[0]);
  }
}


void GroupBy::create_output_and_partition(FFModel& model)
{
  int dim = inputs[0].numDim;
  switch (dim) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      create_output_and_partition_with_dim<DIM>(model); \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
    {
      // Unsupported dim for ElementWiseBinary operator
      assert(false);
    }
  }
}


OpMeta* GroupBy::init_task(const Task* task,
                        const std::vector<PhysicalRegion> &regions,
                        Context ctx, Runtime* runtime)
{
  GroupBy* gb = (GroupBy*) task->args;
  FFHandler handle = *((FFHandler*)task->local_args);
  GroupByMeta* m = new GroupByMeta(handle, gb->n);
  m->profiling = gb->profiling;
  return m;
}


void GroupBy::init(const FFModel& ff)
{
  ArgumentMap argmap;
  Context ctx = ff.config.lg_ctx;
  Runtime* runtime = ff.config.lg_hlr;
  Domain domain = runtime->get_index_space_domain(ctx, task_is);
  switch (domain.get_dim()) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      Rect<DIM> rect = domain; \
      ParallelConfig pc; \
      std::string pcname = name; \
      ff.config.find_parallel_config(DIM, pcname, pc); \
      int idx = 0; \
      for (PointInRectIterator<DIM> it(rect); it(); it++) { \
        FFHandler handle = ff.handlers[pc.device_ids[idx++]]; \
        argmap.set_point(*it, TaskArgument(&handle, sizeof(FFHandler))); \
      } \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
      assert(false);
  }

  IndexLauncher launcher(GROUP_BY_INIT_TASK_ID, task_is,
                         TaskArgument(this, sizeof(GroupBy)), argmap,
                         Predicate::TRUE_PRED, false/*must*/, 0/*mapper_id*/,
                         FFConfig::get_hash_id(std::string(name)));
  // data
  launcher.add_region_requirement(
    RegionRequirement(input_lps[0], 0/*projection id*/,
      READ_ONLY, EXCLUSIVE, inputs[0].region));
  launcher.add_field(0, FID_DATA);
  // assign
  launcher.add_region_requirement(
    RegionRequirement(input_lps[1], 0/*projection id*/,
      READ_ONLY, EXCLUSIVE, inputs[1].region));
  launcher.add_field(1, FID_DATA);
  // output
  for(int i = 0; i < n; i++) {
    launcher.add_region_requirement(
      RegionRequirement(outputs[i].part, 0/*projection id*/,
        WRITE_ONLY, EXCLUSIVE, outputs[i].region));
    launcher.add_field(i+2, FID_DATA);
  }
  FutureMap fm = runtime->execute_index_space(ctx, launcher);
  fm.wait_all_results();
  switch (domain.get_dim()) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      Rect<DIM> rect = domain; \
      int idx = 0; \
      for (PointInRectIterator<DIM> it(rect); it(); it++) { \
        meta[idx++] = fm.get_result<OpMeta*>(*it); \
      } \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
      assert(false);
  }
}


__global__
void gb_forward_kernel(const float* input,
        const int* exp_assign,
        float** outputs,
        int n, // num experts
        int k, // chosen experts
        float alpha, // factor additional memory assigned
        int batch_size,
        int data_dim)
{
  __shared__ float* chosen_exp_preds[MAX_K*MAX_BATCH_SIZE];

  // Get pred pointers, single thread per block
  if(threadIdx.x == 0) {
    int exp_tensor_rows = ceil(alpha*k/n*batch_size);
    int expert_idx[MAX_N] = {0};
    for(int i = 0; i < k*batch_size; i++) {
      // Get pointer to chosen expert predictions
      int expert = exp_assign[i];
      if(expert_idx[expert] >= exp_tensor_rows) {
        // dropped sample
        chosen_exp_preds[i] = 0;
        continue;
      }
      chosen_exp_preds[i] = outputs[expert] + expert_idx[expert]*data_dim;
      expert_idx[expert]++;
    }
  }

  __syncthreads();

  // compute output
  CUDA_KERNEL_LOOP(i, k*batch_size*data_dim)
  {
    if(chosen_exp_preds[i/data_dim] != 0) {
      float a = input[(i/(k*data_dim))*data_dim + i%data_dim];
      chosen_exp_preds[i/data_dim][i%data_dim] = a;
    }
  }
}


__global__
void gb_backward_kernel(float* input_grad,
        const int* exp_assign,
        float** output_grads,
        int n, // num experts
        int k, // chosen experts
        float alpha, // factor additional memory assigned
        int batch_size,
        int data_dim)
{
  __shared__ float* chosen_exp_grads[MAX_K*MAX_BATCH_SIZE];

  // Get pred pointers, single thread
  if(blockIdx.x * blockDim.x + threadIdx.x == 0) {
    int exp_tensor_rows = ceil(alpha*k/n*batch_size);
    int expert_idx[MAX_N] = {0};
    for(int i = 0; i < k*batch_size; i++) {
      // Get pointer to chosen expert predictions
      int expert = exp_assign[i];
      if(expert_idx[expert] >= exp_tensor_rows) {
        // dropped sample
        chosen_exp_grads[i] = 0;
        continue;
      }
      chosen_exp_grads[i] = output_grads[expert] + expert_idx[expert]*data_dim;
      expert_idx[expert]++;
    }
  }

  __syncthreads();

  // compute output
  CUDA_KERNEL_LOOP(i, k*batch_size*data_dim)
  {
    if(chosen_exp_grads[i/data_dim] != 0) {
      input_grad[(i/(k*data_dim))*data_dim + i%data_dim] = chosen_exp_grads[i/data_dim][i%data_dim];
    }
  }
}


template<int NDIM>
void GroupBy::forward_task_with_dim(const Task *task,
                            const std::vector<PhysicalRegion>& regions,
                            Context ctx, Runtime* runtime)
{
  // Get n, alpha
  const GroupBy* gb = (GroupBy*) task->args;
  int n = gb->n;
  float alpha = gb->alpha;

  assert((int)regions.size() == n+2);
  assert((int)task->regions.size() == n+2);

  const GroupByMeta* m = *((GroupByMeta**)task->local_args);

  // get input and assign regions
  const AccessorRO<float, NDIM> acc_input(regions[0], FID_DATA);
  const AccessorRO<int, 2> acc_assign(regions[1], FID_DATA);

  Rect<NDIM> rect_input = runtime->get_index_space_domain(
      ctx, task->regions[0].region.get_index_space());
  Rect<2> rect_assign = runtime->get_index_space_domain(
      ctx, task->regions[1].region.get_index_space());

  int batch_size = rect_assign.hi[1] - rect_assign.lo[1] + 1;
  int data_dim = rect_input.volume()/batch_size;
  assert(batch_size == rect_input.hi[NDIM-1] - rect_input.lo[NDIM-1] + 1);
  int k = rect_assign.hi[0] - rect_assign.lo[0] + 1;

  // get output
  float* outputs[n];
  //int exp_output_rows = (int)ceil(alpha*k/n*batch_size);
  for(int i = 0; i < n; i++) {
    Domain out_domain = runtime->get_index_space_domain(
      ctx, task->regions[i+2].region.get_index_space());
    outputs[i] = helperGetTensorPointerWO<float>(
      regions[i+2], task->regions[i+2], FID_DATA, ctx, runtime);

    //coord_t output_rows = out_domain.hi()[1] - out_domain.lo()[1] + 1;
    // coord_t output_cols = out_domain.hi()[0] - out_domain.lo()[0] + 1;
    //assert((int)output_rows == exp_output_rows);
    // assert(output_cols == input_cols);
  }

#ifndef DISABLE_LEGION_CUDA_HIJACK
  cudaStream_t stream;
  checkCUDA(cudaStreamCreate(&stream));
  checkCUDA(cublasSetStream(m->handle.blas, stream));
  checkCUDNN(cudnnSetStream(m->handle.dnn, stream));
#endif

  // call forward kernel
  cudaMemcpy(m->dev_region_ptrs, outputs, n*sizeof(float*), cudaMemcpyHostToDevice);

  gb_forward_kernel<<<GET_BLOCKS(batch_size*k*data_dim), min(CUDA_NUM_THREADS,(int)(batch_size*k*data_dim))>>>(
    acc_input.ptr(rect_input), acc_assign.ptr(rect_assign), m->dev_region_ptrs, n, k,
    alpha, batch_size, data_dim);
}


void GroupBy::forward_task(const Task *task,
                          const std::vector<PhysicalRegion> &regions,
                          Context ctx, Runtime *runtime)
{
  Domain in_domain = runtime->get_index_space_domain(
      ctx, task->regions[0].region.get_index_space());
  switch (in_domain.get_dim()) {
#define DIMFUNC(DIM) \
    case DIM: \
      return forward_task_with_dim<DIM>(task, regions, ctx, runtime);
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
      assert(false);
  }
}


void GroupBy::backward_task(const Task *task,
                            const std::vector<PhysicalRegion>& regions,
                            Context ctx, Runtime* runtime)
{
  return;
  // Get n, alpha
  const GroupByMeta* m = *((GroupByMeta**)task->local_args);
  const GroupBy* gb = (GroupBy*) task->args;
  int n = gb->n;
  float alpha = gb->alpha;

  assert((int)regions.size() == n+2);
  assert((int)task->regions.size() == n+2);

  // get input and assign regions
  const AccessorWO<float, 2> acc_input_grad(regions[0], FID_DATA);
  const AccessorRO<int, 2> acc_assign(regions[1], FID_DATA);

  Rect<2> rect_input_grad = runtime->get_index_space_domain(
      ctx, task->regions[0].region.get_index_space());
  Rect<2> rect_assign = runtime->get_index_space_domain(
      ctx, task->regions[1].region.get_index_space());

  coord_t input_rows = rect_input_grad.hi[1] - rect_input_grad.lo[1] + 1;
  coord_t input_cols = rect_input_grad.hi[0] - rect_input_grad.lo[0] + 1;
  assert(input_rows == rect_assign.hi[1] - rect_assign.lo[1] + 1);
  int k = rect_assign.hi[0] - rect_assign.lo[0] + 1;
  int batch_size = input_rows;
  int data_dim = input_cols;

  // get output
  float* output_grads[n];
  //int exp_output_rows = (int)ceil(alpha*k/n*batch_size);
  for(int i = 0; i < n; i++) {
    Domain out_domain = runtime->get_index_space_domain(
      ctx, task->regions[i+2].region.get_index_space());
    output_grads[i] = helperGetTensorPointerRW<float>(
      regions[i+2], task->regions[i+2], FID_DATA, ctx, runtime);

    //coord_t output_rows = out_domain.hi()[1] - out_domain.lo()[1] + 1;
    coord_t output_cols = out_domain.hi()[0] - out_domain.lo()[0] + 1;
    //assert((int)output_rows == exp_output_rows);
    assert(output_cols == input_cols);
  }

#ifndef DISABLE_LEGION_CUDA_HIJACK
  cudaStream_t stream;
  checkCUDA(cudaStreamCreate(&stream));
  checkCUDA(cublasSetStream(m->handle.blas, stream));
  checkCUDNN(cudnnSetStream(m->handle.dnn, stream));
#endif

  // call forward kernel
  cudaMemcpy(m->dev_region_ptrs, output_grads, n*sizeof(float*), cudaMemcpyHostToDevice);

  gb_backward_kernel<<<GET_BLOCKS(batch_size*k*data_dim), min(CUDA_NUM_THREADS,(int)(batch_size*k*data_dim))>>>(
    acc_input_grad.ptr(rect_input_grad), acc_assign.ptr(rect_assign), m->dev_region_ptrs,
    n, k, alpha, batch_size, data_dim);
}


void GroupBy::forward(const FFModel& ff)
{
  ArgumentMap argmap;
  Context ctx = ff.config.lg_ctx;
  Runtime* runtime = ff.config.lg_hlr;
  Domain domain = runtime->get_index_space_domain(ctx, task_is);
  switch (domain.get_dim()) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      Rect<DIM> rect = domain; \
      int idx = 0; \
      for (PointInRectIterator<DIM> it(rect); it(); it++) { \
        OpMeta* mp = meta[idx++]; \
        argmap.set_point(*it, TaskArgument(&mp, sizeof(OpMeta*))); \
      } \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
      assert(false);
  }
  IndexLauncher launcher(GROUP_BY_FWD_TASK_ID, task_is,
                         TaskArgument(this, sizeof(GroupBy)), argmap,
                         Predicate::TRUE_PRED, false/*must*/, 0/*mapper_id*/,
                         FFConfig::get_hash_id(std::string(name)));
  // data
  launcher.add_region_requirement(
    RegionRequirement(input_lps[0], 0/*projection id*/,
      READ_ONLY, EXCLUSIVE, inputs[0].region));
  launcher.add_field(0, FID_DATA);

  // assign
  launcher.add_region_requirement(
    RegionRequirement(input_lps[1], 0/*projection id*/,
      READ_ONLY, EXCLUSIVE, inputs[1].region));
  launcher.add_field(1, FID_DATA);

  // output
  for(int i = 0; i < n; i++) {
    launcher.add_region_requirement(
      RegionRequirement(outputs[i].part, 0/*projection id*/,
        WRITE_ONLY, EXCLUSIVE, outputs[i].region));
    launcher.add_field(i+2, FID_DATA);
  }

  runtime->execute_index_space(ctx, launcher);
}

void GroupBy::backward(const FFModel& ff)
{
  // TODO: That GroupBy needs to propagate gradients is unusual.
  // We could check if needs to be propagated and only do if inputs[0] is
  // the output of anyother operator. Else, don't propagate.
  // TODO: backward_task only supports 2D input for now.


  ArgumentMap argmap;
  Context ctx = ff.config.lg_ctx;
  Runtime* runtime = ff.config.lg_hlr;
  Domain domain = runtime->get_index_space_domain(ctx, task_is);
  switch (domain.get_dim()) {
#define DIMFUNC(DIM) \
    case DIM: \
    { \
      Rect<DIM> rect = domain; \
      int idx = 0; \
      for (PointInRectIterator<DIM> it(rect); it(); it++) { \
        OpMeta* mp = meta[idx++]; \
        argmap.set_point(*it, TaskArgument(&mp, sizeof(OpMeta*))); \
      } \
      break; \
    }
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
      assert(false);
  }
  IndexLauncher launcher(GROUP_BY_BWD_TASK_ID, task_is,
                         TaskArgument(this, sizeof(GroupBy)), argmap,
                         Predicate::TRUE_PRED, false/*must*/, 0/*mapper_id*/,
                         FFConfig::get_hash_id(std::string(name)));

  // input_grad
  launcher.add_region_requirement(
    RegionRequirement(input_grad_lps[0], 0/*projection id*/,
      WRITE_ONLY, EXCLUSIVE, inputs[0].region_grad));
  launcher.add_field(0, FID_DATA);

  // assign
  launcher.add_region_requirement(
    RegionRequirement(input_lps[1], 0/*projection id*/,
      READ_ONLY, EXCLUSIVE, inputs[1].region));
  launcher.add_field(1, FID_DATA);

  // output grad
  for(int i = 0; i < n; i++) {
    launcher.add_region_requirement(
      RegionRequirement(outputs[i].part_grad, 0/*projection id*/,
        WRITE_ONLY, EXCLUSIVE, outputs[i].region_grad));
    launcher.add_field(i+2, FID_DATA);
  }

  runtime->execute_index_space(ctx, launcher);
}


GroupByMeta::GroupByMeta(FFHandler handler, int n)
: OpMeta(handler)
{
  checkCUDA(cudaMalloc(&dev_region_ptrs, n*sizeof(float*)));
}
GroupByMeta::~GroupByMeta(void)
{
  checkCUDA(cudaFree(&dev_region_ptrs));
}


bool GroupBy::measure_operator_cost(Simulator* sim,
                                 const ParallelConfig& pc,
                                 CostMetrics& cost_metrics)
{
  //TODO: implement
  cost_metrics.forward_time = 0.0f;
  cost_metrics.backward_time = 0.0f;
  cost_metrics.memory_requirement = 0;
  return false;
}