//
// Intel OPAE ASE simulator does not allow running multiple applications at
// the same time. This wrapper runs both client and server in a single UNIX
// process.
//
// NOTE: there is not such issue when running on a real FPGA, so client and
// server can be launched as independent standalone processes.
//

#include <future>
#include <iostream>
#include <vector>
#include <thread>

#include <assert.h>
#include <unistd.h>

#include "Sample_rpc_client.h"
#include "Sample_rpc_server_callback.h"

#include "rpc_call.h"
#include "rpc_client_pool.h"
#include "rpc_threaded_server.h"


#define FRPC_LOG_LEVEL_GLOBAL FRPC_LOG_LEVEL_INFO
#define NUMBER_OF_THREADS 1
#define NUM_OF_REQUESTS 4

static int run_server(std::promise<bool>& init_pr, std::future<bool>& cmpl_ft);
static int run_server_1(std::promise<bool>& init_pr, std::future<bool>& cmpl_ft);
static int run_client();

int main() {
    // Server #0
    std::promise<bool> init_pr;
    std::future<bool> init_ft = init_pr.get_future();

    std::promise<bool> cmpl_pr;
    std::future<bool> cmpl_ft = cmpl_pr.get_future();

    std::thread server_thread = std::thread(&run_server, std::ref(init_pr), std::ref(cmpl_ft));

    // Server #1
    std::promise<bool> init_pr_1;
    std::future<bool> init_ft_1 = init_pr_1.get_future();

    std::thread server_1_thread = std::thread(&run_server_1, std::ref(init_pr_1), std::ref(cmpl_ft));

    // Wait until servers are set-up
    init_ft.wait();
    init_ft_1.wait();

    // Start client
    std::thread client_thread = std::thread(&run_client);

    // Wait untill client thread is terminated
    client_thread.join();
    cmpl_pr.set_value(true);

    // Wait until server thread is terminated
    server_thread.join();

    return 0;
}


//
// Server part
//
#define SERVER_NIC_ADDR 0x4000
#define CLIENT_2_NIC_ADDR 0x8000

// Nested client for server
static frpc::RpcClientPool<frpc::RpcClient> rpc_client_pool_1(CLIENT_2_NIC_ADDR,
                                                              NUMBER_OF_THREADS);
static frpc::RpcClient* nested_client;

// RPC function #0
static RpcRetCode loopback(CallHandler handler, LoopBackArgs args, NumericalResult* ret) {
    std::cout << "loopback is called with data= " << args.data << std::endl;
    ret->data = args.data + 1;
    nested_client->loopback({args.data + 1});
    return RpcRetCode::Success;
}

// RPC function #1
static RpcRetCode add(CallHandler handler, AddArgs args, NumericalResult* ret) {
    std::cout << "add is called with a= " << args.a << " b= " << args.b << std::endl;
    ret->data = args.a + args.b;
    nested_client->add({args.a + args.b, args.a + args.b});
    return RpcRetCode::Success;
}

static int run_server(std::promise<bool>& init_pr, std::future<bool>& cmpl_ft) {
    frpc::RpcThreadedServer server(SERVER_NIC_ADDR, NUMBER_OF_THREADS);

    // Init
    int res = server.init_nic();
    if (res != 0)
        return res;

    // Start NIC
    res = server.start_nic();
    if (res != 0)
        return res;

    // Register RPC functions
    std::vector<const void*> fn_ptr;
    fn_ptr.push_back(reinterpret_cast<const void*>(&loopback));
    fn_ptr.push_back(reinterpret_cast<const void*>(&add));

    frpc::RpcServerCallBack server_callback(fn_ptr);

    // Open connections
    for (int i=0; i<NUMBER_OF_THREADS; ++i) {
        frpc::IPv4 client_addr("0.0.0.0", 3136);
        if (server.connect(client_addr, i, i) != 0) {
            std::cout << "Failed to open connection on server" << std::endl;
            exit(1);
        } else {
            std::cout << "Connection is open on server" << std::endl;
        }
    }

    // Init nested client
    // Init client pool
    res = rpc_client_pool_1.init_nic();
    if (res != 0)
        return res;

    // Start NIC
    res = rpc_client_pool_1.start_nic();
    if (res != 0)
        return res;

    nested_client = rpc_client_pool_1.pop();
    assert(nested_client != nullptr);

    frpc::IPv4 server_addr("0.0.0.9", 3136);
    if (nested_client->connect(server_addr, 0) != 0) {
        std::cout << "Failed to open connection on client" << std::endl;
        exit(1);
    } else {
        std::cout << "Connection is open on client" << std::endl;
    }

    // Start server threads
    for (int i=0; i<NUMBER_OF_THREADS; ++i) {
        res = server.run_new_listening_thread(&server_callback);
        if (res != 0)
            return res;
    }

    std::cout << "------- Server is running... -------" << std::endl;

    // Notify client thread
    init_pr.set_value(true);

    //
    // Work for a while
    //

    // Wait untill client thread terminates
    cmpl_ft.wait();

    res = server.stop_all_listening_threads();
    if (res != 0)
        return res;

    std::cout << "Server #0 is stopped!" << std::endl;

    // Stop NIC
    res = server.stop_nic();
    if (res != 0)
        return res;

    // Stop nested client NIC
    res = rpc_client_pool_1.stop_nic();
    if (res != 0)
        return res;

    // We wait a little long here since exiting the scope will immediately
    // destroy RpcThreadedServer and de-allocate NIC buffers. The ASE environment
    // can be slow, so if CCI-P transactions are still in-flight when buffers
    // are de-allocated, this might cause errors.
    sleep(10);

    return 0;
}

#define SERVER_1_NIC_ADDR 0x24000

// RPC function #0
static RpcRetCode loopback_1(CallHandler handler, LoopBackArgs args, NumericalResult* ret) {
    std::cout << "loopback_1 is called with data= " << args.data << std::endl;
    ret->data = args.data + 1;
    return RpcRetCode::Success;
}

// RPC function #1
static RpcRetCode add_1(CallHandler handler, AddArgs args, NumericalResult* ret) {
    std::cout << "add_1 is called with a= " << args.a << " b= " << args.b << std::endl;
    ret->data = args.a + args.b;
    return RpcRetCode::Success;
}

static int run_server_1(std::promise<bool>& init_pr, std::future<bool>& cmpl_ft) {
    frpc::RpcThreadedServer server(SERVER_1_NIC_ADDR, NUMBER_OF_THREADS);

    // Init
    int res = server.init_nic();
    if (res != 0)
        return res;

    // Start NIC
    res = server.start_nic();
    if (res != 0)
        return res;

    // Register RPC functions
    std::vector<const void*> fn_ptr;
    fn_ptr.push_back(reinterpret_cast<const void*>(&loopback_1));
    fn_ptr.push_back(reinterpret_cast<const void*>(&add_1));

    frpc::RpcServerCallBack server_callback(fn_ptr);

    // Open connections
    for (int i=0; i<NUMBER_OF_THREADS; ++i) {
        frpc::IPv4 client_addr("0.0.0.2", 3136);
        if (server.connect(client_addr, i, i) != 0) {
            std::cout << "Failed to open connection on server" << std::endl;
            exit(1);
        } else {
            std::cout << "Connection is open on server" << std::endl;
        }
    }

    // Start server threads
    for (int i=0; i<NUMBER_OF_THREADS; ++i) {
        res = server.run_new_listening_thread(&server_callback);
        if (res != 0)
            return res;
    }

    std::cout << "------- Server #1 is running... -------" << std::endl;

    // Notify client thread
    init_pr.set_value(true);

    //
    // Work for a while
    //

    // Wait untill client thread terminates
    cmpl_ft.wait();

    res = server.stop_all_listening_threads();
    if (res != 0)
        return res;

    std::cout << "Server is stopped!" << std::endl;

    // Stop NIC
    res = server.stop_nic();
    if (res != 0)
        return res;

    // We wait a little long here since exiting the scope will immediately
    // destroy RpcThreadedServer and de-allocate NIC buffers. The ASE environment
    // can be slow, so if CCI-P transactions are still in-flight when buffers
    // are de-allocated, this might cause errors.
    sleep(10);

    return 0;
}


//
// Client part
//
#define CLIENT_1_NIC_ADDR 0x00000

static int client(frpc::RpcClient* rpc_client, size_t thread_id, size_t num_of_requests) {
    // Open connection
    frpc::IPv4 server_addr("0.0.0.1", 3136);
    if (rpc_client->connect(server_addr, thread_id) != 0) {
        std::cout << "Failed to open connection on client" << std::endl;
        exit(1);
    } else {
        std::cout << "Connection is open on client" << std::endl;
    }

    // Get completion queue
    frpc::CompletionQueue* cq = rpc_client->get_completion_queue();
    assert(cq != nullptr);

    // Make an RPC call
    for (int i=0; i<num_of_requests; ++i) {
        int res = rpc_client->loopback({thread_id*10 + i});
        assert(res == 0);

        usleep(200000);
    }

    // Wait a bit
    sleep(60);

    // Read completion queue
    size_t n_of_cq_entries = cq->get_number_of_completed_requests();
    std::cout << "Thread " << thread_id << ", CQ entries: " << n_of_cq_entries << std::endl;
    for (int i=0; i<n_of_cq_entries; ++i) {
        std::cout << "Thread " << thread_id << ", RPC returned: "
                  << reinterpret_cast<NumericalResult*>(cq->pop_response().argv)->data
                  << std::endl;
    }

    return 0;
}

static int run_client() {
    frpc::RpcClientPool<frpc::RpcClient> rpc_client_pool(CLIENT_1_NIC_ADDR,
                                                         NUMBER_OF_THREADS);

    // Init client pool
    int res = rpc_client_pool.init_nic();
    if (res != 0)
        return res;

    // Start NIC
    res = rpc_client_pool.start_nic();
    if (res != 0)
        return res;

    // Get client
    std::vector<std::thread> threads;
    for (int i=0; i<NUMBER_OF_THREADS; ++i) {
        frpc::RpcClient* rpc_client = rpc_client_pool.pop();
        assert(rpc_client != nullptr);

        std::thread thr = std::thread(&client,
                                      rpc_client,
                                      i,
                                      NUM_OF_REQUESTS);
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

    // We wait a little long here since exiting the scope will immediately
    // destroy RpcClientPool and de-allocate NIC buffers. The ASE environment
    // can be slow, so if CCI-P transactions are still in-flight when buffers
    // are de-allocated, this might cause errors.
    sleep(10);

    return 0;
}
