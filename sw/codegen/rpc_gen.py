#
# Parser and codegenerator for Dagger IDL
#

#!/usr/bin/python

from codegen import CodeGen

import os
import re
import sys
from shutil import copyfile

CLIENT_FILENAME = "rpc_client.h"
SERVER_FILENAME = "rpc_server_callback.h"
TYPE_HDR_FILENAME = "rpc_types.h"
WRITE_TMPL_FILENAME = "dagger_write.tmpl"

# <proto_type: (C++_type, sizeof)>
type_dict = {
	'char': ('char', 1),
	'int8': ('uint8_t', 1),
	'int16': ('uint16_t', 2),
	'int32': ('uint32_t', 4),
	'int64': ('uint64_t', 8),
	'float': ('float', 4),
	'double': ('double', 8)
}


#
# RPCGenerator class
#
class RPCGenerator:
	#
	# Public
	#
	def __init__(self, idl_file_path, src_file_path):
		self.__idl_file_path = idl_file_path
		self.__src_file_path = src_file_path

	def generate(self):
		idef = self.__read_idl_file()
		iframes = self.__parse_frames(idef)

		# Parse
		imessages = {}
		iservices = {}
		for f_name, f_lines in iframes:
			if f_name == 'message':
				name, arg_list = self.__parse_as_message(f_lines)
				imessages[name] = arg_list

			elif f_name == 'service':
				name, f_list = self.__parse_as_service(f_lines)
				iservices[name] = f_list

			else:
				assert False, "Error parsing frames, undefined token"

		# Generate
		for s_name, s_functions in iservices.items():
			# Type header
			with open(self.__src_file_path + '/' + TYPE_HDR_FILENAME, 'w+') as type_hdr_f:
				type_hdr_f.write(self.__gen_type_hdr(imessages))

			# Service
			with open(self.__src_file_path + '/' + SERVER_FILENAME, 'w+') as server_f:
				server_f.write(self.__gen_service(imessages, s_name, s_functions))

			# Client
			with open(self.__src_file_path + '/' + CLIENT_FILENAME, 'w+') as client_f:
				client_f.write(self.__gen_client(imessages, s_name, s_functions))


	#
	# Private
	#
	def __read_idl_file(self):
		idef = []
		with open(self.__idl_file_path) as file:
			for l in file:
				idef.append(l)

		return idef

	def __parse_frames(self, idef):
		frames = []
		frame = []
		for l in idef:
			if l == "" or l == "\n":
				continue

			l = l.rstrip("\n").lstrip()

			if l.startswith('/*'):
				if not l.endswith('*/'):
					assert False, "Wrong format of a comment"

				continue

			elif l.endswith('{'):
				regexp = r"^(message|service) .* {$"
				m = re.search(regexp, l)
				if not m == None:
					frame_name = m.group(1)
				else:
					assert False, "Error parsing frames, wrong frame header"

				frame.append(l)

			elif l.startswith('}'):
				if not l == '}':
					assert False, "Error parsing frames, nothing is expected after }"

				frame.append(l)
				frames.append((frame_name, frame))
				frame = []

			else:
				regexp = r"^.*;$"
				m = re.search(regexp, l)
				if not m == None:
					frame.append(l)
				else:
					assert False, "Error parsing frames, missing ; in <" + l + ">"

		return frames

	def __parse_as_message(self, frame):
		arg_list = []
		for l, i in zip(frame, range(len(frame))):
			if i == 0:
				# First line
				regexp = r"^message ([a-zA-Z][a-zA-Z0-9_]*) {$"
				m = re.search(regexp, l)
				if not m == None:
					m_name = m.group(1)
				else:
					assert False, "Message parsing error, wrong header format"

			elif i < len(frame)-1:
				# Body lines
				regexp_simple = r"^([a-z][a-z0-9]*) ([a-zA-Z][a-zA-Z0-9_]*);$"
				regexp_array = r"^([a-z][a-z0-9]*)\[([0-9]+)\] ([a-zA-Z][a-zA-Z0-9_]*);$"
				m = re.search(regexp_simple, l)
				if not m == None:
					arg_type = m.group(1)
					arg_name = m.group(2)
					arg_list.append((arg_type, arg_name, None))
				else:
					m = re.search(regexp_array, l)
					if not m == None:
						arg_type = m.group(1)
						arg_array_size = int(m.group(2))
						arg_name = m.group(3)
						arg_list.append((arg_type, arg_name, arg_array_size))
					else:
						assert False, "Message parsing error, wrong body format in line <" + l + ">"

			else:
				# Last line
				if not l == '}':
					assert False, "Message parsing error, missing }"
				else:
					return (m_name, arg_list)

	def __parse_as_service(self, frame):
		f_list = []
		f_id = 0
		for l, i in zip(frame, range(len(frame))):
			if i == 0:
				# First line
				regexp = r"^service ([a-zA-Z][a-zA-Z0-9_]*) {$"
				m = re.search(regexp, l)
				if not m == None:
					s_name = m.group(1)
				else:
					assert False, "Service parsing error, wrong header format"

			elif i < len(frame)-1:
				# Body lines
				regexp = r"^rpc ([a-zA-Z][a-zA-Z0-9_]*)\(([a-zA-Z][a-zA-Z0-9_]*)\) returns \(([a-zA-Z][a-zA-Z0-9_]*)\);$"
				m = re.search(regexp, l)
				if not m == None:
					f_name = m.group(1)
					arg_name = m.group(2)
					ret_name = m.group(3)
					f_list.append((f_name, arg_name, ret_name, f_id))
					f_id = f_id + 1
				else:
					assert False, "Service parsing error, wrong body format"

			else:
				# Last line
				if not l == '}':
					assert False, "Service parsing error, missing }"
				else:
					return (s_name, f_list)

	def __gen_service(self, imessages, s_name, s_functions):
		print("generating service " + s_name)

		c_codegen = CodeGen()

		# Generate skeleton
		skeleton_header = \
"""
/*
 * Autogenerated with rpc_gen.py
 *
 *        DO NOT CHANGE
*/
#ifndef _RPC_SERVER_CALLBACK_H_
#define _RPC_SERVER_CALLBACK_H_

#include "logger.h"
#include "rpc_call.h"
#include "rpc_header.h"
#include "rpc_server_thread.h"
#include "rx_queue.h"
#include "utils.h"

#include "rpc_types.h"

#include <cstring>
#include <immintrin.h>

namespace dagger {

class RpcServerCallBack: public RpcServerCallBack_Base {
public:
	RpcServerCallBack(const std::vector<const void*>& rpc_fn_ptr):
		RpcServerCallBack_Base(rpc_fn_ptr) {}
	~RpcServerCallBack() {};

	virtual void operator()(const CallHandler handler,
	                        const RpcPckt* rpc_in, TxQueue& tx_queue) const final {
		uint8_t ret_buff[cfg::sys::cl_size_bytes];
		size_t ret_size;
		RpcRetCode ret_code;

		// Check the fn_id is withing the scope
		if (rpc_in->hdr.fn_id > rpc_fn_ptr_.size() - 1) {
			FRPC_ERROR("Too large RPC function id is received, this call will stop here and "
					   "no value will be returned\\n");
			return;
		}

"""
		c_codegen.append_snippet(skeleton_header)

		# Generate function calls
		c_codegen.append(self.__switch_block(
							'rpc_in->hdr.fn_id',
							[str(f[3]) for f in s_functions],
							[self.__gen_casted_f_call(f, imessages) for f in s_functions],
							2
						))

		# Generate
		skeleton_ret_code_check = \
"""
		if (ret_code == RpcRetCode::Fail) {
			FRPC_ERROR("RPC returned an error, this call will stop here and "
					   "no value will be returned\\n");
			return;
		}
"""
		c_codegen.append_snippet(skeleton_ret_code_check)

		skeleton_change_bit = \
"""
		uint8_t change_bit;
		char* tx_ptr = tx_queue.get_write_ptr(change_bit);

"""
		c_codegen.append_snippet(skeleton_change_bit)

		# Append return code
		c_codegen.append_from_file(WRITE_TMPL_FILENAME)

		c_codegen.replace('<CONN_ID>', 'rpc_in->hdr.c_id')
		c_codegen.replace('<RPC_ID>', 'rpc_in->hdr.rpc_id')
		c_codegen.replace('<FUN_NUM_OF_FRAMES>', str(1))
		c_codegen.replace('<FUN_FUNCTION_ID>', str(1))
		c_codegen.replace('<FUN_ARG_LENGTH_BYTES>', 'ret_size')
		c_codegen.replace('<REQ_TYPE>', 'rpc_response')

		# Make data layout for MMIO-based interface
		c_codegen.seek('/*DATA_LAYOUT_MMIO*/')
		c_codegen.remove_token('/*DATA_LAYOUT_MMIO*/')
		c_codegen.append(
			self.__new_line(
			self.__memcpy('request.argv', 'ret_buff', 'ret_size'), 2)
		)

		# Make data layout for polling- and DMA-based interfaces
		for i in range(2):
			c_codegen.seek('/*DATA_LAYOUT*/')
			c_codegen.remove_token('/*DATA_LAYOUT*/')
			c_codegen.append(
				self.__new_line(
				self.__memcpy('tx_ptr_casted->argv', 'ret_buff', 'ret_size'), 2)
			)

		skeleton_footer = \
"""
	}

};

}  // namespace dagger

#endif // _RPC_SERVER_CALLBACK_H_
"""
		c_codegen.append_snippet(skeleton_footer)
		return c_codegen.get_code()

	def __gen_casted_f_call(self, fn, imessages):
		arg_name = fn[1]
		ret_name = fn[2]
		rpc_id = fn[3]

		cast_string = self.__assignment('ret_code',
					  self.__new_line(
					  self.__f_call(
						  self.__closure(
						  self.__dereference(
						  self.__reinterpret_cast('RpcRetCode(*)(' + 'CallHandler' + ', '
						  										   + arg_name + ', '
						  	                                       + self.__make_ptr(ret_name) + ')',
							                      'rpc_fn_ptr_[' + str(rpc_id) + ']')
						  )),

						  'handler' + ', ' +
						  self.__dereference(
						  self.__reinterpret_cast(
						  	self.__make_const(self.__make_ptr(arg_name)),
						    'rpc_in->argv')) + ', ' +
						  self.__reinterpret_cast(
						  	self.__make_ptr(ret_name),
							'ret_buff')
					  )
		))

		# Gen return size
		ret_size_string = self.__new_line(self.__assignment('ret_size', 'sizeof(' + ret_name + ')'), 4)

		return cast_string + ret_size_string

	def __gen_client(self, imessages, s_name, s_functions):
		print("generating cient for service " + s_name)
		for f in s_functions:
			print("  <" + f[2] + " " + f[0] + "(" + f[1] + "))>")

		c_codegen = CodeGen()

		# Generate skeleton header
		skeleton_header = \
"""
/*
 * Autogenerated with rpc_gen.py
 *
 *        DO NOT CHANGE
*/
#ifndef _RPC_CLIENT_NONBLOCKING_H_
#define _RPC_CLIENT_NONBLOCKING_H_

#include "logger.h"
#include "rpc_client_nonblocking_base.h"
#include "utils.h"

#include "rpc_types.h"

#include <cstring>
#include <immintrin.h>

namespace dagger {

class RpcClient: public RpcClientNonBlock_Base {
public:
    RpcClient(const Nic* nic, size_t nic_flow_id, uint16_t client_id):
        RpcClientNonBlock_Base(nic, nic_flow_id, client_id) {}
    virtual ~RpcClient() {}

    virtual void abstract_class() const { return; }

    // Remote function section
"""
		c_codegen.append_snippet(skeleton_header)

		# Generate function calls
		for f in s_functions:
			f_codegen = CodeGen()

			# Get name and args
			f_name = f[0]
			arg_name = f[1]
			f_id = str(f[3])
			if arg_name in imessages:
				msg = imessages[arg_name]
			else:
				assert False, "Message type " + arg_name + " not found"

			# Generate function prototype
			f_codegen.append(self.__function(
								'int', f_name, self.__make_const(self.__make_ref(arg_name)) + ' args', 1));

			# Generate function header
			f_codegen.append(
"""
	    // Get current buffer pointer
	    uint8_t change_bit;
	    char* tx_ptr = tx_queue_.get_write_ptr(change_bit);
	    if (tx_ptr >= nic_->get_tx_buff_end()) {
	        FRPC_ERROR("Nic tx buffer overflow \\n");
	        assert(false);
	    }
	    assert(reinterpret_cast<size_t>(tx_ptr) % nic_->get_mtu_size_bytes() == 0);

	    // Make RPC id
	    uint32_t rpc_id = client_id_ | static_cast<uint32_t>(rpc_id_cnt_ << 16);
""")
			# Append buffer writing template
			f_codegen.append_from_file(WRITE_TMPL_FILENAME)

			# Make RPC parameters
			f_codegen.replace('<CONN_ID>', 'c_id_')
			f_codegen.replace('<RPC_ID>', 'rpc_id')
			f_codegen.replace('<FUN_NUM_OF_FRAMES>', str(1))
			f_codegen.replace('<FUN_FUNCTION_ID>', f_id)
			f_codegen.replace('<FUN_ARG_LENGTH_BYTES>', 'sizeof(' + arg_name + ')')
			f_codegen.replace('<REQ_TYPE>', 'rpc_request')

			# Make data layout for MMIO-based interface
			f_codegen.seek('/*DATA_LAYOUT_MMIO*/')
			f_codegen.remove_token('/*DATA_LAYOUT_MMIO*/')
			f_codegen.append(
				self.__new_line(
				self.__memcpy('request.argv',
					          self.__reinterpret_cast(self.__make_const(self.__make_ptr('void')), self.__pointer('args')),
					          'sizeof(' + arg_name + ')'), 2)
			)

			# Make data layout for polling- and DMA-based interfaces
			for i in range(2):
				f_codegen.seek('/*DATA_LAYOUT*/')
				f_codegen.remove_token('/*DATA_LAYOUT*/')
				f_codegen.append(self.__new_line(
								 self.__assignment(
									 self.__dereference(
									 self.__reinterpret_cast(
									 	self.__make_ptr(arg_name),
									 	'tx_ptr_casted->argv')),
									 'args'), 2)
				)

			# Generate function footer
			f_codegen.append("""

        ++rpc_id_cnt_;

        return 0;
}\n""")

			# Append function
			c_codegen.append_codegen(f_codegen)

		# Generate skeleton footer
		skeleton_footer = \
"""
};

}  // namespace dagger

#endif // _RPC_CLIENT_NONBLOCKING_H_
"""

		c_codegen.append_snippet(skeleton_footer)
		return c_codegen.get_code()

	def __gen_type_hdr(self, imessages):
		skeleton_header = \
"""
#ifndef _RPC_TYPES_H_
#define _RPC_TYPES_H_

"""
		body = ""
		for (name, arg_list) in imessages.items():
			body = body + self.__c_struct(name, arg_list)
			body = body + '\n'

		skeleton_footer = \
"""
#endif	// _RPC_TYPES_H_
"""

		return skeleton_header + body + skeleton_footer


	# Expression builders
	def __offset(self, data, offset):
		return data + ' + ' + str(offset)

	def __reinterpret_cast(self, type_, data):
		return 'reinterpret_cast<' + type_ + '>(' + data + ')';

	def __dereference(self, expr):
		return '*' + expr

	def __assignment(self, lvaue, rvalue):
		return lvaue + " = " + rvalue

	def __closure(self, expr):
		return '(' + expr + ')'

	def __f_call(self, fn, args):
		return fn + '(' + args + ')'

	def __new_line(self, expr, tabs=0):
		return "".join(['\t']*tabs) + expr + ';\n'

	def __make_ptr(self, expr):
		return expr + '*'

	def __make_ref(self, expr):
		return expr + '&'

	def __pointer(self, expr):
		return '&' + expr

	def __make_const(self, expr):
		return 'const ' + expr

	def __var_def(self, type_, name):
		return type_ + ' ' + name

	def __switch_block(self, var_name, case_var_list, case_list, tabs=0):
		result = "".join(['\t']*tabs) + 'switch (' + var_name + ') {\n'
		for case_var, case in zip(case_var_list, case_list):
			result = result + "".join(['\t']*(tabs+1)) + 'case ' + case_var + ': {\n'
			result = result + "".join(['\t']*(tabs+2)) + case
			result = result + "".join(['\t']*(tabs+2)) + 'break;\n'
			result = result + "".join(['\t']*(tabs+1)) + '}\n'
		result = result + "".join(['\t']*tabs) + '}\n'

		return result

	def __function(self, ret_type, name, args, tabs=0):
		return "".join(['\t']*tabs) + ret_type + ' ' + name + '(' + args + ') {\n'

	def __c_struct(self, name, arg_list, tabs=0):
		result = "".join(['\t']*tabs) + "struct " + name + " {\n";
		for (arg_type, arg_name, arg_array_size) in arg_list:
			if arg_array_size == None:
				# Simple field
				result = result + "".join(['\t']*(tabs+1)) + type_dict[arg_type][0] + ' ' + arg_name + ';\n'
			else:
				# Array field
				result = result + "".join(['\t']*(tabs+1)) + type_dict[arg_type][0] + ' ' \
				                + arg_name + '[' + str(arg_array_size) + ']' + ';\n'

		result = result + "".join(['\t']*tabs) + "};\n"

		return result;

	def __memcpy(self, dest, src, size):
		return "memcpy(" + dest + ', ' + src + ', ' + size + ")"


#
# Main
#
def main():
	rpc_gen = RPCGenerator(sys.argv[1], sys.argv[2])
	rpc_gen.generate()

if __name__ == "__main__":
	main()
