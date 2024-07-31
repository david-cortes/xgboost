/**
 * Copyright 2022-2023 by XGBoost Contributors
 */

#include <thrust/iterator/counting_iterator.h>  // thrust::make_counting_iterator

#include <cstddef>  // size_t

#include "cuda_context.cuh"    // CUDAContext
#include "device_helpers.cuh"  // dh::MakeTransformIterator, tcbegin, tcend
#include "linalg_op.cuh"       // for tcbegin, tcend
#include "optional_weight.h"   // common::OptionalWeights
#include "stats.cuh"           // common::SegmentedQuantile, common::SegmentedWeightedQuantile
#include "xgboost/base.h"      // for XGBOOST_DEVICE
#include "xgboost/context.h"   // for Context
#include "xgboost/host_device_vector.h"  // for HostDeviceVector
#include "xgboost/linalg.h"              // for TensorView, UnravelIndex, Apply

namespace xgboost::common::cuda_impl {
void Median(Context const* ctx, linalg::TensorView<float const, 2> t,
            common::OptionalWeights weights, linalg::Tensor<float, 1>* out) {
  CHECK_GE(t.Shape(1), 1);
  HostDeviceVector<std::size_t> segments(t.Shape(1) + 1, 0);
  segments.SetDevice(ctx->Device());
  auto d_segments = segments.DeviceSpan();
  dh::LaunchN(d_segments.size(), ctx->CUDACtx()->Stream(),
              [=] XGBOOST_DEVICE(std::size_t i) { d_segments[i] = t.Shape(0) * i; });
  auto val_it = dh::MakeTransformIterator<float>(
      thrust::make_counting_iterator(0ul), [=] XGBOOST_DEVICE(size_t i) {
        return linalg::detail::Apply(t, linalg::UnravelIndex(i, t.Shape()));
      });

  out->SetDevice(ctx->Device());
  out->Reshape(t.Shape(1));
  if (weights.Empty()) {
    common::SegmentedQuantile(ctx, 0.5, dh::tcbegin(d_segments), dh::tcend(d_segments), val_it,
                              val_it + t.Size(), out->Data());
  } else {
    CHECK_NE(t.Shape(1), 0);
    auto w_it = dh::MakeTransformIterator<float>(thrust::make_counting_iterator(0ul),
                                                 [=] XGBOOST_DEVICE(std::size_t i) {
                                                   auto sample_idx = i / t.Shape(1);
                                                   return weights[sample_idx];
                                                 });
    common::SegmentedWeightedQuantile(ctx, 0.5, dh::tcbegin(d_segments), dh::tcend(d_segments),
                                      val_it, val_it + t.Size(), w_it, w_it + t.Size(),
                                      out->Data());
  }
}

void Mean(Context const* ctx, linalg::VectorView<float const> v, linalg::VectorView<float> out) {
  float n = v.Size();
  auto it = dh::MakeTransformIterator<float>(
      thrust::make_counting_iterator(0ul), [=] XGBOOST_DEVICE(std::size_t i) { return v(i) / n; });
  std::size_t bytes;
  CHECK_EQ(out.Size(), 1);
  auto s = ctx->CUDACtx()->Stream();
  cub::DeviceReduce::Sum(nullptr, bytes, it, out.Values().data(), v.Size(), s);
  dh::TemporaryArray<char> temp{bytes};
  cub::DeviceReduce::Sum(temp.data().get(), bytes, it, out.Values().data(), v.Size(), s);
}

void SampleMean(Context const* ctx, linalg::MatrixView<float const> d_v,
                linalg::VectorView<float> d_out) {
  auto column_it = dh::MakeTransformIterator<std::size_t>(thrust::make_counting_iterator(0ul),
                                                          [=] XGBOOST_DEVICE(std::size_t i) {
                                                            auto cidx = i / d_v.Shape(0);
                                                            return cidx;
                                                          });
  auto n_rows_f32 = static_cast<float>(d_v.Shape(0));
  auto val_it = dh::MakeTransformIterator<float>(thrust::make_counting_iterator(0ul),
                                                 [=] XGBOOST_DEVICE(std::size_t i) {
                                                   auto cidx = i / d_v.Shape(0);
                                                   auto ridx = i % d_v.Shape(0);
                                                   return d_v(ridx, cidx) / n_rows_f32;
                                                 });
  auto cuctx = ctx->CUDACtx();
  thrust::reduce_by_key(cuctx->CTP(), column_it, column_it + d_v.Size(), val_it,
                        thrust::make_discard_iterator(), d_out.Values().data());
}

void WeightedSampleMean(Context const* ctx, linalg::MatrixView<float const> d_v,
                        linalg::VectorView<float const> d_w, linalg::VectorView<float> d_out) {
  CHECK(d_v.CContiguous());
  auto column_it = dh::MakeTransformIterator<std::size_t>(thrust::make_counting_iterator(0ul),
                                                          [=] XGBOOST_DEVICE(std::size_t i) {
                                                            auto cidx = i / d_v.Shape(0);
                                                            return cidx;
                                                          });
  auto cuctx = ctx->CUDACtx();
  auto sum_w = dh::Reduce(cuctx->CTP(), linalg::tcbegin(d_w), linalg::tcend(d_w), 0.0f,
                          thrust::plus<float>{});
  auto val_it = dh::MakeTransformIterator<float>(thrust::make_counting_iterator(0ul),
                                                 [=] XGBOOST_DEVICE(std::size_t i) {
                                                   auto cidx = i / d_v.Shape(0);
                                                   auto ridx = i % d_v.Shape(0);
                                                   return d_v(ridx, cidx) * d_w(ridx) / sum_w;
                                                 });
  thrust::reduce_by_key(cuctx->CTP(), column_it, column_it + d_v.Size(), val_it,
                        thrust::make_discard_iterator(), d_out.Values().data());
}
}  // namespace xgboost::common::cuda_impl
