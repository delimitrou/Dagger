#include <unistd.h>

#include <algorithm>
#include <cassert>
#include <cinttypes>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <vector>

#include "defs.h"
#include "config.h"
#include "rpc_call.h"
#include "rpc_client.h"
#include "rpc_client_pool.h"
#include "rpc_types.h"
#include "utils.h"
#include "CLI11.hpp"

// HW parameters
#ifdef PLATFORM_PAC_A10
    #ifdef NIC_PHY_NETWORK
        // Allocate FPGA on bus_1 for the client when running on PAC_A10 with physical networking
        static constexpr int fpga_bus = dagger::cfg::platform::pac_a10_fpga_bus_1;

        // If physical networking, running on different FPGAs, so NIC is placed by 0x20000
        // for both client and server
        static constexpr uint64_t nic_address = 0x20000;

    #else
        // Allocate FPGA on bus_1 for the client when running on PAC_A10 with loopback networking
        static constexpr int fpga_bus = dagger::cfg::platform::pac_a10_fpga_bus_1;

        // If loopback, running on the same FPGA, so NIC is placed by 0x00000 for client
        // and 0x20000 for server
        static constexpr uint64_t nic_address = 0x00000;

    #endif
#else
    // Only loopback is possible here, so -1 for bus and 0x00000 for address
    static constexpr int fpga_bus = -1;
    static constexpr uint64_t nic_address = 0x00000;

#endif

static int run_benchmark(dagger::RpcClient* rpc_client,
                             int thread_id,
                             size_t num_iterations,
                             size_t req_delay,
                             double cycles_in_ns,
                             int function_to_call);

static double rdtsc_in_ns() {
    uint64_t a = dagger::utils::rdtsc();
    sleep(1);
    uint64_t b = dagger::utils::rdtsc();

    return (b - a)/1000000000.0;
}

// <number of threads, number of requests per thread, RPC issue delay, function>
enum TestType {performance, correctness};

int main(int argc, char* argv[]) {
    // Parse input
    CLI::App app{"Benchmark Client"};

    size_t num_of_threads;
    app.add_option("-t, --threads", num_of_threads, "number of threads")->required();
    size_t num_of_requests;
    app.add_option("-r, --requests", num_of_requests, "number of requests")->required();
    size_t req_delay;
    app.add_option("-d, --delay", req_delay, "delay")->required();
    std::string fn_name;
    app.add_option("-f, --function", fn_name, "function to call")->required();

    CLI11_PARSE(app, argc, argv);

    int function_to_call = 0;
    if (fn_name == "loopback")
        function_to_call = 0;
    else if (fn_name == "add")
        function_to_call = 1;
    else if (fn_name ==  "sign")
        function_to_call = 2;
    else if (fn_name == "xor")
        function_to_call = 3;
    else if (fn_name == "getUserData")
        function_to_call = 4;
    else {
        std::cout << "wrong parameter: function name" << std::endl;
        return 1;
    }

    // Get time/freq
    double cycles_in_ns = rdtsc_in_ns();
    std::cout << "Cycles in ns: " << cycles_in_ns << std::endl;

    // RClient
    dagger::RpcClientPool<dagger::RpcClient> rpc_client_pool(nic_address,
                                                         num_of_threads);

    // Init client pool
    int res = rpc_client_pool.init_nic(fpga_bus);
    if (res != 0)
        return res;

    // Start NIC
    res = rpc_client_pool.start_nic();
    if (res != 0)
        return res;

    // Enable perf
    res = rpc_client_pool.run_perf_thread({true, true, true, true}, nullptr);
    if (res != 0)
        return res;

    sleep(1);

    // Run client threads
    std::vector<std::thread> threads;
    for (int thread_id=0; thread_id<num_of_threads; ++thread_id) {
        dagger::RpcClient* rpc_client = rpc_client_pool.pop();
        assert(rpc_client != nullptr);

        // Open connection
        dagger::IPv4 server_addr("192.168.0.2", 3136);
        if (rpc_client->connect(server_addr, thread_id) != 0) {
            std::cout << "Failed to open connection on client" << std::endl;
            exit(1);
        } else {
            std::cout << "Connection is open on client" << std::endl;
        }

        std::thread thr = std::thread(&run_benchmark,
                                      rpc_client,
                                      thread_id,
                                      num_of_requests,
                                      req_delay,
                                      cycles_in_ns,
                                      function_to_call);
        threads.push_back(std::move(thr));
    }

    for (auto& thr: threads) {
        thr.join();
    }

    // Check for HW errors
    res = rpc_client_pool.check_hw_errors();
    if (res != 0)
        std::cout << "HW errors found, check error log" << std::endl;
    else
        std::cout << "No HW errors found" << std::endl;

    // Stop NIC
    res = rpc_client_pool.stop_nic();
    if (res != 0)
        return res;

    return 0;
}

static bool sortbysec(const uint64_t &a, const uint64_t &b) {
    return a < b;
}

static int run_benchmark(dagger::RpcClient* rpc_client,
                         int thread_id,
                         size_t num_iterations,
                         size_t req_delay,
                         double cycles_in_ns,
                         int function_to_call) {
    // Make an RPC call
    for(int i=0; i<num_iterations; ++i) {
        switch (function_to_call) {
            case 0: rpc_client->loopback({dagger::utils::rdtsc(), i}); break;

            case 1: rpc_client->add({dagger::utils::rdtsc(), i, i+1}); break;

            case 2: rpc_client->sign({dagger::utils::rdtsc(),
                                     0xaabbccdd,
                                     0x11223344,
                                     i, i+1, i+2, i+3}); break;

            case 3: rpc_client->xor_({dagger::utils::rdtsc(),
                                     i, i+1, i+2, i+3, i+4, i+5}); break;

            case 4: {
                UserName request;
                request.timestamp = dagger::utils::rdtsc();
                sprintf(request.first_name, "Buffalo");
                sprintf(request.given_name, "Bill");

                rpc_client->getUserData(request);
                break;
            }
        }

        // Blocking delay to control rps rate
        for (int delay=0; delay<req_delay; ++delay) {
            asm("");
        }
    }

    // Wait a bit
    sleep(5);

    // Get data
    auto cq = rpc_client->get_completion_queue();
    size_t cq_size = cq->get_number_of_completed_requests();
    std::cout << "Thread #" << thread_id << ": CQ size= " << cq_size << std::endl;

#ifdef VERBOSE_RPCS
    // Output data
    for (int i=0; i<cq_size; ++i) {
        switch (function_to_call) {
            case 0:
            case 1:
            case 3: {
                std::cout << reinterpret_cast<NumericalResult*>(cq->pop_response().argv)->ret_val << std::endl;
                break;
            }

            case 2: {
                std::cout << reinterpret_cast<Signature*>(cq->pop_response().argv)->result << std::endl;
                break;
            }

            case 4: {
                std::cout << reinterpret_cast<UserData*>(cq->pop_response().argv)->data << std::endl;
                break;
            }
        }
    }
#endif

    // Get latency profile
    auto latency_records = cq->get_latency_records();

    std::sort(latency_records.begin(), latency_records.end(), sortbysec);

    if (latency_records.size() != 0) {
        std::cout << "***** latency results for thread #" << thread_id
                  << " *****" << std::endl;
        std::cout << "  total records= " << latency_records.size() << std::endl;
        std::cout << "  median= "
                  << latency_records[latency_records.size()*0.5]/cycles_in_ns
                  << " ns" << std::endl;
        std::cout << "  90th= "
                  << latency_records[latency_records.size()*0.9]/cycles_in_ns
                  << " ns" << std::endl;
        std::cout << "  99th= "
                  << latency_records[latency_records.size()*0.99]/cycles_in_ns
                  << " ns" << std::endl;
    }

    return 0;
}
