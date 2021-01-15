#ifndef _CLIENT_SERVER_PAIR_H_
#define _CLIENT_SERVER_PAIR_H_

/*
 * ********** IMPORTANT ***********
 * ********************************
 * ** Configure all batches to 1 **
 */

#include "rpc_call.h"
#include "rpc_client.h"
#include "rpc_client_pool.h"
#include "rpc_server_callback.h"
#include "rpc_threaded_server.h"

class ClientServerPair: public ::testing::Test {
protected:
    static constexpr size_t timeout = 5;
    static constexpr uint64_t loopback1_const = 10;

    // Don't change
    static constexpr uint64_t server_nic_mmio_base = 0x20000;
    static constexpr uint64_t client_nic_mmio_base = 0x00000;

    virtual void SetUp(size_t num_of_threads_, bool with_stat = false) {
        ASSERT_EQ(frpc::cfg::nic::l_rx_batch_size, 0);

        num_of_threads = num_of_threads_;

        server = std::unique_ptr<frpc::RpcThreadedServer>(
                    new frpc::RpcThreadedServer(    
                        server_nic_mmio_base, num_of_threads)
                    );

        client_pool = std::unique_ptr<frpc::RpcClientPool<frpc::RpcClient>>(
                        new frpc::RpcClientPool<frpc::RpcClient>(
                            client_nic_mmio_base, num_of_threads)
                        );

        // Setup server
        int res = server->init_nic();
        ASSERT_EQ(res, 0);

        res = server->start_nic();
        ASSERT_EQ(res, 0);

        fn_ptr.push_back(reinterpret_cast<const void*>(&ClientServerPair::loopback1));
        fn_ptr.push_back(reinterpret_cast<const void*>(&ClientServerPair::loopback2));
        fn_ptr.push_back(reinterpret_cast<const void*>(&ClientServerPair::loopback3));
        fn_ptr.push_back(reinterpret_cast<const void*>(&ClientServerPair::loopback4));
        fn_ptr.push_back(reinterpret_cast<const void*>(&ClientServerPair::loopback5));
        server_callback = std::unique_ptr<frpc::RpcServerCallBack>(
                                                new frpc::RpcServerCallBack(fn_ptr));

        for(int i=0; i<num_of_threads; ++i) {
            res = server->run_new_listening_thread(server_callback.get());
            ASSERT_EQ(res, 0);
        }

        // Open-up connections
        frpc::IPv4 client_addr("192.168.0.2", 3136);
        for (int i=0; i<num_of_threads; ++i) {
            ASSERT_EQ(server->connect(client_addr, i, i), 0);
        }

        // Setup clients
        res = client_pool->init_nic();
        ASSERT_EQ(res, 0);

        res = client_pool->start_nic();
        ASSERT_EQ(res, 0);
    }

    virtual void TearDown() override {
        // Shutdown server
        int res = server->stop_all_listening_threads();
        ASSERT_EQ(res, 0);

        res = server->stop_nic();
        ASSERT_EQ(res, 0);

        res = server->check_hw_errors();
        ASSERT_EQ(res, 0);

        // Shutdown clients
        res = client_pool->stop_nic();
        ASSERT_EQ(res, 0);

        res = client_pool->check_hw_errors();
        ASSERT_EQ(res, 0);
    }

    // RPC functions
    static RpcRetCode loopback1(CallHandler handler, Arg1 arg, Ret1* ret) {
        ret->f_id = 0;
        ret->ret_val = arg.a + loopback1_const;

        return RpcRetCode::Success;
    }

    static RpcRetCode loopback2(CallHandler handler, Arg2 arg, Ret1* ret) {
        ret->f_id = 1;
        ret->ret_val = arg.a + arg.b + arg.c + arg.d;

        return RpcRetCode::Success;
    }

    static RpcRetCode loopback3(CallHandler handler, Arg3 arg, Ret1* ret) {
        ret->f_id = 2;
        ret->ret_val = (arg.a)*(arg.b) + (arg.c)*(arg.d);

        return RpcRetCode::Success;
    }

    static RpcRetCode loopback4(CallHandler handler, Arg3 arg, Ret2* ret) {
        ret->f_id = 3;
        ret->ret_val = arg.a*arg.b + arg.c*arg.d;
        ret->ret_val_1 = arg.a*arg.c + arg.b*arg.d;

        return RpcRetCode::Success;
    }

    static RpcRetCode loopback5(CallHandler handler, StringArg arg, StringRet* ret) {
        ret->f_id = 4;
        sprintf(ret->str, arg.str);

        return RpcRetCode::Success;
    }

    size_t num_of_threads;

    std::unique_ptr<frpc::RpcThreadedServer> server;
    std::vector<const void*> fn_ptr;
    std::unique_ptr<frpc::RpcServerCallBack> server_callback;

    std::unique_ptr<frpc::RpcClientPool<frpc::RpcClient>> client_pool;

};

#endif  // _CLIENT_SERVER_PAIR_H_
