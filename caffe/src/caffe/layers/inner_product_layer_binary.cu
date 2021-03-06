#include <vector>

#include "caffe/filler.hpp"
#include "caffe/layers/inner_product_layer_binary.hpp"
#include "caffe/util/math_functions.hpp"

namespace caffe {

template <typename Dtype>
void BinaryInnerProductLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
    const vector<Blob<Dtype>*>& top) {
  // Initialization
  const Dtype* bottom_data = bottom[0]->gpu_data();
  Dtype* top_data = top[0]->mutable_gpu_data();
  Dtype* weight = this->blobs_[0]->mutable_gpu_data();
  const int num = this-> N_;
  const int kel = this-> K_;
  const int N = num * kel;
  Dtype* binaryweight = binary_weight_.mutable_gpu_data();
  caffe_copy<Dtype>(N, weight, binaryweight);
  
  // quantize the weights and save the signs into binaryweight
  caffe_gpu_binarize<Dtype>(weight, binaryweight, this->all_quantized_.gpu_data(), num, kel);
  caffe_gpu_binary_scaling<Dtype>(weight, binaryweight, this->all_quantized_.gpu_data(), &alpha_, num, kel);
  
  // Stochastic Quantization
  if (this->sq_ && (this->ratio_ < 100)){
    // roulette selection algorithm; mask is stored in 'is_quantized'
	Roulette();
    // convert the weights to a hybrid weight
	caffe_gpu_binarize<Dtype>(weight, binaryweight, this->is_quantized_.gpu_data(), num, kel);
    caffe_gpu_binary_scaling<Dtype>(weight, binaryweight, this->is_quantized_.gpu_data(), &alpha_, num, kel);
  }
  
  // Inner product
  if (M_ == 1) {
    caffe_gpu_gemv<Dtype>(CblasNoTrans, N_, K_, (Dtype)1.,
                         binaryweight, bottom_data, (Dtype)0., top_data);
    if (bias_term_)
      caffe_gpu_axpy<Dtype>(N_, bias_multiplier_.cpu_data()[0],
                            this->blobs_[1]->gpu_data(), top_data);
  } else {
    caffe_gpu_gemm<Dtype>(CblasNoTrans,
                          transpose_ ? CblasNoTrans : CblasTrans,
                          M_, N_, K_, (Dtype)1.,
                          bottom_data, binaryweight, (Dtype)0., top_data);
    if (bias_term_)
      caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasNoTrans, M_, N_, 1, (Dtype)1.,
                            bias_multiplier_.gpu_data(),
                            this->blobs_[1]->gpu_data(), (Dtype)1., top_data);
  }
}

template <typename Dtype>
void BinaryInnerProductLayer<Dtype>::Roulette() {
  const Dtype* weight = this->blobs_[0]->gpu_data();
  const int num = this->N_;
  const int weight_col = this->K_;
  const int N = num * weight_col;
  const Dtype* binaryweight = binary_weight_.gpu_data();
  const float ratio = this->ratio_;
  Dtype* norm = error_norm_.mutable_cpu_data();
  Dtype* ns = sum_norm_.mutable_cpu_data();
  Dtype* wc = weight_copy_.mutable_gpu_data();
  
// calculate the quantization error(||W-Q||/||W||)
  caffe_gpu_sub(N, weight, binaryweight, wc);
  for(int n = 0; n < num; n++) {
    caffe_gpu_asum(weight_col, wc + n * weight_col, norm + n);
    caffe_gpu_asum(weight_col, weight + n * weight_col, ns + n);
  }
  for(int n = 0; n < num; n++) {
    if (ns[n] == 0) {
      norm[n] = 0;
    } else {
      norm[n] = norm[n] / ns[n]; // quantization errors are stored in 'norm'
    }
  }
  int* is_quant = is_quantized_.mutable_cpu_data();
	
  // roulette
  Dtype sum = 0;
  for(int n = 0; n < num; n++) {
    sum += norm[n];
    is_quant[n] = 1;
  }
  const int real_num = int((1 - ratio / 100) * num);
  for(int i = 0; i < real_num; i++) { // select one kernel which is set to real. the probability is equal to norm
    Dtype p;
    caffe_rng_uniform(1, Dtype(0), Dtype(1), &p);
    p *= sum;
    Dtype cur_sum = 0;
    for(int n = 0; n < num; n++) {
      if(is_quant[n] == 1) { // not selected
        if((p >= cur_sum) && (p < cur_sum + norm[n])) { // hit
          is_quant[n] = 0;
          sum -= norm[n]; // remove
          break;
		}
        else {
          cur_sum += norm[n];
        }
	  }
    }
  }
}

template void BinaryInnerProductLayer<float>::Roulette();
template void BinaryInnerProductLayer<double>::Roulette();

template <typename Dtype>
void BinaryInnerProductLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
    const vector<bool>& propagate_down,
    const vector<Blob<Dtype>*>& bottom) {
  if (this->param_propagate_down_[0]) {
    const Dtype* top_diff = top[0]->gpu_diff();
    const Dtype* bottom_data = bottom[0]->gpu_data();
    // Gradient with respect to weight
    if (transpose_) {
      caffe_gpu_gemm<Dtype>(CblasTrans, CblasNoTrans,
          K_, N_, M_,
          (Dtype)1., bottom_data, top_diff,
          (Dtype)1., this->blobs_[0]->mutable_gpu_diff());
    } else {
      caffe_gpu_gemm<Dtype>(CblasTrans, CblasNoTrans,
          N_, K_, M_,
          (Dtype)1., top_diff, bottom_data,
          (Dtype)1., this->blobs_[0]->mutable_gpu_diff());
    }
  }
  if (bias_term_ && this->param_propagate_down_[1]) {
    const Dtype* top_diff = top[0]->gpu_diff();
    // Gradient with respect to bias
    caffe_gpu_gemv<Dtype>(CblasTrans, M_, N_, (Dtype)1., top_diff,
        bias_multiplier_.gpu_data(), (Dtype)1.,
        this->blobs_[1]->mutable_gpu_diff());
  }
  if (propagate_down[0]) {
    const Dtype* top_diff = top[0]->gpu_diff();
    // Gradient with respect to bottom data
    if (transpose_) {
      caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasTrans,
          M_, K_, N_,
          (Dtype)1., top_diff, binary_weight_.gpu_data(),
          (Dtype)0., bottom[0]->mutable_gpu_diff());
    } else {
      caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasNoTrans,
          M_, K_, N_,
         (Dtype)1., top_diff, binary_weight_.gpu_data(),
         (Dtype)0., bottom[0]->mutable_gpu_diff());
    }
  }
}

INSTANTIATE_LAYER_GPU_FUNCS(BinaryInnerProductLayer);

}  // namespace caffe
