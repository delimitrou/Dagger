/**
 * @file nic_ccip_dma.h
 * @brief Implementation of the CCI-P-based DMA nic.
 * @author Nikita Lazarev
 */
#ifndef _NIC_CCIP_DMA_H_
#define _NIC_CCIP_DMA_H_

#include <opae/fpga.h>
#include <stddef.h>
#include <stdint.h>

#include <mutex>

#include "nic_ccip.h"

namespace dagger {

#define CL(x) ((x)*cfg::sys::cl_size_bytes)

/// DMA-based CCIP NIC.
/// Provides software support for CCI-P DMA.
///
/// Inheritance hierarchy:
///   Nic -> NicCCIP -> NicPollingCCIP
///                  -> NicMmioCCIP
///                  -> NicDmaCCIP
///
class NicDmaCCIP : public NicCCIP {
 public:
  NicDmaCCIP(uint64_t base_rf_addr, size_t num_of_flows, bool master_nic);
  virtual ~NicDmaCCIP();

  virtual int start() final;
  virtual int stop() final;

  virtual int configure_data_plane() final;

  // Make sure to sync memory before calling this function.
  virtual int notify_nic_of_new_dma(size_t flow, size_t bucket) const final;

  virtual char* get_tx_flow_buffer(size_t flow) const final {
    return const_cast<char*>(buf_) + tx_offset_bytes_ +
           flow * tx_queue_size_bytes_;
  }

  virtual volatile char* get_rx_flow_buffer(size_t flow) const final {
    return buf_ + rx_offset_bytes_ + flow * rx_queue_size_bytes_;
  }

  virtual const char* get_tx_buff_end() const final {
    return const_cast<char*>(buf_) + tx_offset_bytes_ + tx_buff_size_bytes_;
  }
  virtual const char* get_rx_buff_end() const final {
    return const_cast<char*>(buf_) + rx_offset_bytes_ + rx_buff_size_bytes_;
  }

 private:
  // Number of Nic flows.
  // one flow = one CPU-NIC communication channel.
  size_t num_of_flows_;

  // Shared with the NIC buffer.
  volatile char* buf_;

  // Buffer id.
  uint64_t wsid_;

  // NIC-viewed physical address of the buffer.
  uint64_t buf_pa_;

  // Tx and Rx offsets.
  size_t tx_offset_bytes_;
  size_t rx_offset_bytes_;

  // Tx and Rx sizes.
  size_t tx_buff_size_bytes_;
  size_t rx_buff_size_bytes_;

  // Flow size.
  size_t tx_queue_size_bytes_;
  size_t rx_queue_size_bytes_;

  // NIC notification mutex.
  mutable std::mutex dma_notification_lock_;
};

}  // namespace dagger

#endif
