{. passC: gorge("pkg-config --cflags fuse") .}
{. passL: gorge("pkg-config --libs fuse") .}

import reply
import posix
import os
import protocol
import Buf
import logging

type fuse_args {. importc:"struct fuse_args", header:"<fuse.h>" .} = object
  argc: cint
  argv: cstringArray
  allocated: cint

# type fuse_chan {. importc:"struct fuse_chan", header:"<fuse.h>" .} = object

proc fuse_mount_compat25(mountpoint: cstring, args: ptr fuse_args): cint {. importc, header:"<fuse.h>" .}
proc fuse_unmount_compat22(mountpoint: cstring) {. importc, header: "<fuse.h>" .}

# proc fuse_mount(mountpoint: cstring, args: ptr fuse_args): ptr fuse_chan {. importc, header:"<fuse.h>" .}
# proc fuse_unmount(mountpoint: cstring, ch: ptr fuse_chan) {. importc, header:"<fuse.h>" .}
# proc fuse_chan_fd(ch: ptr fuse_chan): cint {. importc, header:"<fuse.h>" .}

type Channel* = ref object 
  mount_point: string
  fd: cint
  # raw_chan: ptr fuse_chan

proc connect*(mount_point: string, mount_options: openArray[string]): Channel =
  var args = fuse_args (
    argc: mount_options.len.cint,
    argv: allocCStringArray(mount_options),
    allocated: 0, # control freeing by ourselves
  )
  let fd = fuse_mount_compat25(mount_point, addr(args))
  debug("fd:$1", fd)
  # let ch = fuse_mount(mount_point, addr(args))
  deallocCStringArray(args.argv)
  # Channel(mount_point:mount_point, fd:fuse_chan_fd(ch), raw_chan:ch)
  Channel(mount_point:mount_point, fd:fd)

proc disconnect*(chan: Channel) =
  fuse_unmount_compat22(chan.mount_point)
  # use_unmount(chan.mount_point, chan.raw_chan)

# Read /dev/fuse into a provided buffer
# success: 0
# failure: error value (< 0)
proc fetch*(chan: Channel, buf: Buf): int =
  buf.initPos

  # TODO
  # don't read twice
  
  let header_sz = sizeof(fuse_in_header)
  debug("fetch start. fd:$1", chan.fd)
  # let n = posix.read(chan.fd, buf.asPtr, header_sz)
  let n = posix.read(chan.fd, buf.asPtr, buf.len)
  debug("fetch end 1. n:$1", n)
  # Read syscall may be interrupted and may return before full read.
  # We handle this case as failure because the the position of cursor
  # in this case isn't defined.
  if (n < header_sz):
    debug("fetch error 1. n:$1", n)
    return -posix.EIO
  elif n < 0:
    debug("fetch error 2. n:$1", n)
    return n

  let header = pop[fuse_in_header](buf)
  let remained_len = header.len.int - header_sz
  let n2 = posix.read(chan.fd, buf.asPtr, remained_len)
  if (n2 < remained_len):
    debug("fetch error 3")
    return -posix.EIO
  
  debug("fetch end")
  return 0

type ChannelSender = ref object of Sender
  chan: Channel

proc send(self: ChannelSender, dataSeq: openArray[Buf]): int =
  let n = dataSeq.len.cint
  var iov = newSeq[TIOVec](n)
  for i in 0..n-1:
    iov[i].iov_base = dataSeq[i].asPtr
    iov[i].iov_len = len(dataSeq[i])
  posix.writev(self.chan.fd, addr(iov[0]), n)

proc mkSender*(self: Channel): ChannelSender =
  ChannelSender(chan: self)

when isMainModule:
  let ch0 = channel.connect("./mnt0", @[])
  let ch1 = channel.connect("./mnt1", @[])
  disconnect(ch0)
  disconnect(ch1)
