#include <iostream>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/generate.h>
#include <thrust/sort.h>
#include <cstdlib>
#include <trove/transpose.h>
#include <trove/aos.h>
#include <trove/print_array.h>

#include <thrust/device_vector.h>
#include <thrust/equal.h>


using namespace trove;

template<typename T>
__global__ void benchmark_contiguous_shfl_store(T* r) {
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    T data;
    int size = detail::size_in_ints<T>::value;
    data = counting_array<T>::impl(
        global_index * size);
    store_aos(data, r, global_index);
}

template<typename T>
__global__ void benchmark_contiguous_direct_store(T* r) {
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    T data;
    int size = detail::size_in_ints<T>::value;
    data = counting_array<T>::impl(
        global_index * size);
    r[global_index] = data;
}

template<typename T>
__global__ void benchmark_contiguous_shfl_load_store(T* s, T* r) {
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    T data = load_aos(s, global_index);
    store_aos(data, r, global_index);
}

template<typename T>
__global__ void benchmark_contiguous_direct_load_store(T* s, T* r) {
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    T data = s[global_index];
    r[global_index] = data;
}

template<typename T>
__global__ void benchmark_shfl_gather(const int* indices, T* s, T* r) {
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    int index = indices[global_index];
    T data = load_aos(s, index);
    store_aos(data, r, global_index);
}

template<typename T>
__global__ void benchmark_shfl_scatter(const int* indices, T* s, T* r) {
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    int index = indices[global_index];
    T data = load_aos(s, global_index);
    store_aos(data, r, index);
}

template<typename T>
__global__ void benchmark_direct_gather(const int* indices, T* s, T* r) {
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    int index = indices[global_index];
    T data = s[index];
    r[global_index] = data;
}

template<typename T>
__global__ void benchmark_direct_scatter(const int* indices, T* s, T* r) {
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    int index = indices[global_index];
    T data = s[global_index];
    r[index] = data;
}

template<int i>
void run_benchmark_contiguous_store(const std::string name, void (*test)(array<int, i>*),
                                    void (*gold)(array<int, i>*)) {
    typedef array<int, i> T;

    std::cout << name << ", " << i << ", ";
    int n_blocks = 15 * 8 * 100;
    int block_size = 256;
    int n = n_blocks * block_size;
    thrust::device_vector<T> r(n);
    int iterations = 10;
    cudaEvent_t start, stop;
    float time = 0;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start, 0);
    for(int j = 0; j < iterations; j++) {
        test<<<n_blocks, block_size>>>(thrust::raw_pointer_cast(r.data()));
    }
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time, start, stop);
    float gbs = (float)(sizeof(T) * (iterations * n_blocks * block_size)) / (time * 1000000);
    std::cout << gbs << ", ";
    bool correct = true;
    if (test != gold) {
        thrust::device_vector<T> g(n);
        gold<<<n_blocks, block_size>>>(thrust::raw_pointer_cast(g.data()));
        correct = thrust::equal(r.begin(), r.end(), g.begin());
    }
    if (correct)
        std::cout << "Results passed";
    else
        std::cout << "INCORRECT";
    std::cout << std::endl;
    
}

template<int i>
struct run_benchmark_contiguous_shfl_store {
    typedef array<int, i> T;
    static void impl() {
        run_benchmark_contiguous_store("Contiguous SHFL Store", &benchmark_contiguous_shfl_store<T>,
                                       &benchmark_contiguous_direct_store<T>);
    }
};

template<int i>
struct run_benchmark_contiguous_direct_store {
    typedef array<int, i> T;
    static void impl() {
        run_benchmark_contiguous_store("Contiguous Direct Store", &benchmark_contiguous_direct_store<T>,
                                       &benchmark_contiguous_direct_store<T>);
    }
};



template<typename T>
void fill_test(thrust::device_vector<T>& d) {
    thrust::device_ptr<int> p = thrust::device_ptr<int>((int*)thrust::raw_pointer_cast(d.data()));
    thrust::counting_iterator<int> c(0);
    int s = d.size() * sizeof(T) / sizeof(int);
    thrust::copy(c, c+s, p);
}

template<int i>
void run_benchmark_contiguous_load_store(const std::string name, void (*test)(array<int, i>*, array<int, i>*),
                                         void (*gold)(array<int, i>*, array<int, i>*)) {
    typedef array<int, i> T;

    std::cout << name << ", " << i << ", ";
    int n_blocks = 15 * 8 * 100;
    int block_size = 256;
    int n = n_blocks * block_size;
    thrust::device_vector<T> s(n);
    fill_test(s);
    thrust::device_vector<T> r(n);
    int iterations = 10;
    cudaEvent_t start, stop;
    float time = 0;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start, 0);
    for(int j = 0; j < iterations; j++) {
        test<<<n_blocks, block_size>>>(thrust::raw_pointer_cast(s.data()), thrust::raw_pointer_cast(r.data()));
    }
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time, start, stop);
    float gbs = (float)(2 * sizeof(T) * (iterations * n_blocks * block_size)) / (time * 1000000);
    std::cout << gbs << ", ";
    bool correct = true;
    if (test != gold) {
        thrust::device_vector<T> g(n);
        gold<<<n_blocks, block_size>>>(thrust::raw_pointer_cast(s.data()), thrust::raw_pointer_cast(g.data()));
        correct = thrust::equal(r.begin(), r.end(), g.begin());
    }
    
    if (correct)
        std::cout << "Results passed";
    else
        std::cout << "INCORRECT";
    std::cout << std::endl;
            
    
}

template<int i>
struct run_benchmark_contiguous_shfl_load_store {
    typedef array<int, i> T;
    static void impl() {
        run_benchmark_contiguous_load_store("Contiguous SHFL Load/Store", &benchmark_contiguous_shfl_load_store<T>, &benchmark_contiguous_direct_load_store<T>);
    }
};

template<int i>
struct run_benchmark_contiguous_direct_load_store {
    typedef array<int, i> T;
    static void impl() {
        run_benchmark_contiguous_load_store("Contiguous Direct Load/Store", &benchmark_contiguous_direct_load_store<T>, &benchmark_contiguous_direct_load_store<T>);
    }
};

thrust::device_vector<int> make_device_random(int s) {
    thrust::host_vector<int> h(s);
    thrust::generate(h.begin(), h.end(), rand);
    thrust::device_vector<int> d = h;
    return d;
}

thrust::device_vector<int> make_random_permutation(int s) {
    thrust::device_vector<int> keys = make_device_random(s);
    thrust::counting_iterator<int> c(0);
    thrust::device_vector<int> values(s);
    thrust::copy(c, c+s, values.begin());
    thrust::sort_by_key(keys.begin(), keys.end(), values.begin());
    return values;
}

template<int i>
void run_benchmark_random(const std::string name, const thrust::device_vector<int>& permutation,
                          void (*test)(const int*, array<int, i>*, array<int, i>*),
                          void (*gold)(const int*, array<int, i>*, array<int, i>*)) {
    typedef array<int, i> T;

    std::cout << name << ", " << i << ", ";
    int n_blocks = 15 * 8 * 100;
    int block_size = 256;
    int n = n_blocks * block_size;
    thrust::device_vector<T> s(n);
    fill_test(s);
    thrust::device_vector<T> r(n);
    int iterations = 10;
    cudaEvent_t start, stop;
    float time = 0;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start, 0);
    for(int j = 0; j < iterations; j++) {
        test<<<n_blocks, block_size>>>(
            thrust::raw_pointer_cast(permutation.data()),
            thrust::raw_pointer_cast(s.data()),
            thrust::raw_pointer_cast(r.data()));
    }
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time, start, stop);
    float gbs = (float)(sizeof(T) * (2 * iterations * n_blocks * block_size) + sizeof(int) * iterations * n_blocks * block_size) / (time * 1000000);
    std::cout << gbs << ", ";
    bool correct = true;
    if (test != gold) {
        thrust::device_vector<T> g(n);
        gold<<<n_blocks, block_size>>>(thrust::raw_pointer_cast(permutation.data()),
                                       thrust::raw_pointer_cast(s.data()), thrust::raw_pointer_cast(g.data()));
        correct = thrust::equal(r.begin(), r.end(), g.begin());
    }
    if (correct)
        std::cout << "Results passed";
    else
        std::cout << "INCORRECT";
    std::cout << std::endl;
}

template<int i>
struct run_benchmark_shfl_gather {
    typedef array<int, i> T;
    static void impl(const thrust::device_vector<int>& permutation) {
        run_benchmark_random("SHFL Gather", permutation, &benchmark_shfl_gather<T>, &benchmark_direct_gather<T>);
    }
};

template<int i>
struct run_benchmark_direct_gather {
    typedef array<int, i> T;
    static void impl(const thrust::device_vector<int>& permutation) {
        run_benchmark_random("Direct Gather", permutation, &benchmark_direct_gather<T>, &benchmark_direct_gather<T>);
    }
};

template<int i>
struct run_benchmark_shfl_scatter {
    typedef array<int, i> T;
    static void impl(const thrust::device_vector<int>& permutation) {
        run_benchmark_random("SHFL Scatter", permutation, &benchmark_shfl_scatter<T>, &benchmark_direct_scatter<T>);
    }
};
template<int i>
struct run_benchmark_direct_scatter {
    typedef array<int, i> T;
    static void impl(const thrust::device_vector<int>& permutation) {
        run_benchmark_random("Direct Scatter", permutation, &benchmark_direct_scatter<T>, &benchmark_direct_scatter<T>);
    }
};

template<template<int> class F, typename Cons>
struct do_tests {
    static void impl() {
        F<Cons::head>::impl();
        do_tests<F, typename Cons::tail>::impl();
    }
    template<typename T>
    static void impl(const T& t) {
        F<Cons::head>::impl(t);
        do_tests<F, typename Cons::tail>::impl(t);
    }
};

template<template<int> class F>
struct do_tests<F, null_type> {
    static void impl() {}
    template<typename T>
    static void impl(const T& t) {}
};

#ifndef LOWER_BOUND
#define LOWER_BOUND 2
#endif
#ifndef UPPER_BOUND
#define UPPER_BOUND 16
#endif

typedef static_range<LOWER_BOUND, UPPER_BOUND> sizes;

int main() {
    do_tests<run_benchmark_contiguous_shfl_store, sizes>::impl();
    do_tests<run_benchmark_contiguous_direct_store, sizes>::impl();
    do_tests<run_benchmark_contiguous_shfl_load_store, sizes>::impl();
    do_tests<run_benchmark_contiguous_direct_load_store, sizes>::impl();
    int size = 15 * 8 * 100 * 256;
    thrust::device_vector<int> permutation = make_random_permutation(size);
    do_tests<run_benchmark_shfl_scatter, sizes>::impl(permutation);
    do_tests<run_benchmark_direct_scatter, sizes>::impl(permutation);
    do_tests<run_benchmark_shfl_gather, sizes>::impl(permutation);
    do_tests<run_benchmark_direct_gather, sizes>::impl(permutation);

}

