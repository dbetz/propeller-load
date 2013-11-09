{
  SPI SD driver
  by David Betz

  Based on code from VMCOG - virtual memory server for the Propeller
  Copyright (c) February 3, 2010 by William Henning

  and on code from SdramCache
  Copyright (c) 2010 by John Steven Denson (jazzed)

  Modified to interface to the SD card on the C3 or other boards that use
  a single pin for the chip select - Dave Hein, 11/7/11
  Converted from Spin/PASM to GAS assembly - Dave Hein, 11/12/11

  SDHC Initialization added by Ted Stefanik, 3/15/2012,
  based on fsrw's safe_spi.spin by Jonathan "lonesock" Dummer
  Copyright 2009  Tomas Rokicki and Jonathan Dummer

  TERMS OF USE: MIT License

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.
}

'----------------------------------------------------------------------------------------------------
' Constants
'----------------------------------------------------------------------------------------------------

CON

  ' address of CLKFREQ in hub RAM
  CLKFREQ_ADDR            = $0000

  ' SD commands
  CMD0_GO_IDLE_STATE      = $40 | 0
  CMD1_SEND_OP_COND       = $40 | 1
  CMD8_SEND_IF_COND_CMD   = $40 | 8
  CMD16_SET_BLOCKLEN      = $40 | 16
  CMD17_READ_SINGLE_BLOCK = $40 | 17
  CMD24_WRITE_BLOCK       = $40 | 24
  CMD55_APP_CMD           = $40 | 55
  ACMD41_SD_APP_OP_COND   = $40 | 41
  CMD58_READ_OCR          = $40 | 58
  CMD59_CRC_ON_OFF        = $40 | 59
  
  ' protocol bits
  CS_CLR_PIN_MASK       = $01
  INC_PIN_MASK          = $02   ' for C3-style CS
  MUX_START_BIT_MASK    = $04   ' low order bit of mux field
  MUX_WIDTH_MASK        = $08   ' width of mux field
  ADDR_MASK             = $10   ' device number for C3-style CS or value to write to the mux

OBJ
  int: "cache_interface"

PUB image
  return @init

DAT
        org   $0

'----------------------------------------------------------------------------------------------------
' Driver initialization
'----------------------------------------------------------------------------------------------------

init    jmp     #init2

' sdspi_config1: 0xiiooccpp - ii=mosi oo=miso cc=sck pp=protocol
' sdspi_config2: 0xaabbccdd - aa=cs-or-clr bb=inc-or-start cc=width dd=addr
' the protocol byte is a bit mask with the bits defined above
'   if CS_CLR_PIN_MASK ($01) is set, then byte aa contains the CS or C3-style CLR pin number
'   if INC_PIN_MASK ($02) is set, then byte bb contains the C3-style INC pin number
'   if MUX_START_BIT_MASK ($04) is set, then byte bb contains the starting bit number of the mux field
'   if MUX_WIDTH_MASK ($08) is set, then byte cc contains the width of the mux field
'   if ADDR_MASK ($10) is set, then byte dd contains either the C3-style address or the value to write to the mux field

' These two values get patched by the loader
sdspi_config1 long    $090a0b13 ' for the c3 (di=9, do=10, clk=11, protocol=CS_CLR_PIN_MASK|INC_PIN_MASK|ADDR_MASK)
sdspi_config2 long    $19080005 ' for the c3 (clr=25, inc=8, addr=5)

init2   mov     pvmcmd, par             ' Get the address of the mailbox
        mov     pvmaddr, pvmcmd         ' pvmaddr is the error return code (in cache drivers it is a pointer into the cache line on return)
        add     pvmaddr, #4

        ' build the mosi mask
        mov     t1, sdspi_config1
        shr     t1, #24
        mov     mosi_mask, #1
        shl     mosi_mask, t1
        or      spidir, mosi_mask
        
        ' build the miso mask
        mov     t1, sdspi_config1
        shr     t1, #16
        and     t1, #$ff
        mov     miso_mask, #1
        shl     miso_mask, t1
        
        ' build the sck mask
        mov     t1, sdspi_config1
        shr     t1, #8
        and     t1, #$ff
        mov     sck_mask, #1
        shl     sck_mask, t1
        or      spidir, sck_mask
        
        ' handle the CS or C3-style CLR pins
        test    sdspi_config1, #CS_CLR_PIN_MASK wz
  if_nz mov     t1, sdspi_config2
  if_nz shr     t1, #24
  if_nz mov     cs_clr, #1
  if_nz shl     cs_clr, t1
  if_nz or      spidir, cs_clr
  
        ' handle the mux width
        test    sdspi_config1, #MUX_WIDTH_MASK wz
  if_nz mov     t1, sdspi_config2
  if_nz shr     t1, #8
  if_nz and     t1, #$ff
  if_nz mov     mask_inc, #1
  if_nz shl     mask_inc, t1
  if_nz sub     mask_inc, #1
  if_nz or      spidir, mask_inc
  
        ' handle the C3-style address or mux value
        test    sdspi_config1, #ADDR_MASK wz
  if_nz mov     select_addr, sdspi_config2
  if_nz and     select_addr, #$ff

        ' get the INC pin or the mux start bit
        mov     t1, sdspi_config2
        shr     t1, #16
        and     t1, #$ff

        ' handle the C3-style INC pin
        test    sdspi_config1, #INC_PIN_MASK wz
  if_nz mov     mask_inc, #1
  if_nz shl     mask_inc, t1
  if_nz mov     sd_select, c3_sd_select_jmp     ' We're in C3 mode, so replace sd_select/sd_release
  if_nz mov     sd_release, c3_sd_release_jmp   ' with the C3-aware routines
  if_nz or      spidir, mask_inc
 
        ' handle the mux start bit (must follow setting of select_addr and mask_inc)
        test    sdspi_config1, #MUX_START_BIT_MASK wz
  if_nz shl     select_addr, t1
  if_nz shl     mask_inc, t1
  if_nz or      spidir, mask_inc
        
        ' set the pin directions
        mov     outa, cs_clr
        or      outa, mosi_mask                ' Need to set output high so reads work correctly
        mov     dira, spidir
        call    #sd_release

        rdlong  sdFreq, #CLKFREQ_ADDR   ' Get the clock frequency

'----------------------------------------------------------------------------------------------------
' Command loop
'----------------------------------------------------------------------------------------------------

waitcmd mov     dira, #0                ' Release the pins for other SPI clients
nlk_spi nop        

_wait0  wrlong  zero, pvmcmd
_wait   rdlong  vmline, pvmcmd wz
  if_z  jmp     #_wait

lck_spi test    $, #0 wc                ' lock no-op: clear the carry bit
   if_c jmp     #lck_spi
        mov     dira, spidir            ' Set the pins back so we can use them

        test    vmline, #int#EXTEND_MASK wz ' Test for an extended command
  if_nz jmp     #waitcmd

'----------------------------------------------------------------------------------------------------
' Extended command
'----------------------------------------------------------------------------------------------------

extend  mov     vmaddr, vmline
        shr     vmaddr, #8
        shr     vmline, #2
        and     vmline, #7
        add     vmline, #dispatch
        jmp     vmline

dispatch
        jmp     #waitcmd
        jmp     #waitcmd
        jmp     #waitcmd
        jmp     #sd_init_handler
        jmp     #sd_read_handler
        jmp     #sd_write_handler
        jmp     #waitcmd
'       jmp     #lock_set_handler - This is the next instruction - no need to waste a long

'------------------------------------------------------------------------------
' SPI Bus Lock
'------------------------------------------------------------------------------

lock_set_handler
nlk_ini nop                     ' Unlock previous lock
        mov     lock_id, vmaddr
        mov     lck_spi, lock_set
        mov     nlk_spi, lock_clr
        mov     nlk_ini, lock_clr
        mov     dira, #0        ' Go back to wait command, but skip bus unlock
        jmp     #_wait0
lock_set
        lockset lock_id wc
lock_clr
        lockclr lock_id
lock_id long    0               ' lock id for optional bus interlock

'------------------------------------------------------------------------------
' SD Card Initialization
'------------------------------------------------------------------------------

' The following initialization code conforms to the diagrams on pp114-115 of
' Part_1_Physical_Layer_Simplified_Specification_Ver_3.01_Final_100518.pdf
' fouund at sdcard.org.  We used fsrw's safe_spi.spin as a template of how to
' implement these diagrams in the following code, only this code does not
' duplicate the "the card said CMDo ('go idle') was invalid, so we're possibly
' stuck in read or write mode" section - this appears to be only applicable to
' multi-block read/write, and the PropGCC code uses and supports neither.

sd_init_handler
        mov     sdError, #0             ' Assume no errors
        call    #sd_release

        mov     t1, sdInitCnt
_init   call    #spiRecvByte            ' Output a stream of 32K clocks
        djnz    t1, #_init              '  in case SD card left in some

        call    #sd_select
        mov     count, #10

_cmd0   mov     sdOp, #CMD0_GO_IDLE_STATE
        mov     sdParam, #0
        mov     sdCRC, #$95
        call    #sdSendCmd
        cmp     data, #1 wz             ' Wait until response is In Idle
  if_e  jmp     #_iniOK
        djnz    count, #_cmd0
        mov     sdError, #3             ' Error: Reset failed after 10 attempts
        jmp     #sd_finish

_iniOK  mov     adrShift, #9
        mov     sdBlkCnt, cnt           ' We overload sdBlkCnt as part of master timer during init
        mov     count, sdFreq           ' We overload count as part of master timer during init
        shl     count, #2               ' All initialization must be done in 4 seconds
        
_cmd8   mov     sdOp, #CMD8_SEND_IF_COND_CMD
        mov     sdParam, sd3_3V
        mov     sdCRC, #$87
        call    #sdSendCmd
        cmp     data, #1 wz             ' Wait until response is In Idle
  if_ne jmp     #_type1

        call    #spiRecvLong
        cmp     data, sd3_3V
  if_ne mov     sdError, #4             ' Error: 3.3V Not Supported
  if_ne jmp     #sd_finish

_type2  mov     sdParam1, ccsbit        ' CMD41 is necessary for both type 1 and 2
        mov     sdCRC, #$77             ' but with different paramaters and CRC, so
        call    #_cmd41                 ' it's in a subroutine.

_cmd58  mov     sdOp, #CMD58_READ_OCR
        mov     sdParam, #0
        mov     sdCRC, #$FD
        call    #sdSendCmd
        cmp     data, #0 wz
  if_ne mov     sdError, #5             ' Error: READ_OCR Failed
  if_ne jmp     #sd_finish

        call    #spiRecvLong            ' Check the SDHC bit
        test    data, ccsbit wz
  if_nz mov     adrShift, #0
        jmp     #_ifini

_type1  mov     sdParam1, #0
        mov     sdCRC, #$E5
        call    #_cmd41i

        cmp     data, #1 wc,wz
   if_a jmp     #_typMMC

_initsd call    #_cmd41

_cmd16  mov     sdOp, #CMD16_SET_BLOCKLEN
        mov     sdParam, sdBlkSize
        mov     sdCRC, #$15
        call    #sdSendCmd
        jmp     #_ifini

_typMMC mov     sdOp, #CMD1_SEND_OP_COND
        mov     sdParam, sdBlkSize
        mov     sdCRC, #$F9
        call    #sdSendCmd
        jmp     #_cmd16

_cmd41  call    #_cmd41i
        tjnz    data, #_cmd41            ' Wait until we the card idles
_cmd41_ret
        ret

_cmd41i call    #check_time              ' This routine does not wait until idle -
        mov     sdOp, #CMD55_APP_CMD     ' it just does one ACMD41, then returns.
        mov     sdParam, #0
        mov     sdCRC, #$65
        call    #sdSendCmd
        cmp     data, #1 wc,wz
  if_a  jmp     #_cmd41
        mov     sdOp, #ACMD41_SD_APP_OP_COND
        mov     sdParam, sdParam1
        mov     sdCRC, sdCRC1
        call    #sdSendCmd
_cmd41i_ret
        ret

check_time
        mov     t1, cnt
        sub     t1, sdBlkCnt            ' Check for expired timeout (1 sec)
        cmp     t1, count wc
  if_nc mov     sdError, #6             ' Error: Didn't totally initialize in 4 secs
  if_nc jmp     #sd_finish
check_time_ret
        ret

_ifini  mov     sdOp, #CMD59_CRC_ON_OFF ' Sad, but we don't have the code space nor
        mov     sdParam, #0             ' bandwidth to protect read/writes with CRCs.
        mov     sdCRC, #$91
        call    #sdSendCmd

        call    #spiRecvLong            ' Drain the previous command
        jmp     #sd_finish

'------------------------------------------------------------------------------
' Block read/write
'------------------------------------------------------------------------------

sd_read_handler
        mov     sdError, #0             ' Assume no errors
        rdlong  hubaddr, vmaddr         ' Get the buffer pointer
        add     vmaddr, #4
        rdlong  count, vmaddr wz        ' Get the byte count
  if_z  jmp     #sd_finish
        add     vmaddr, #4
        rdlong  vmaddr, vmaddr          ' Get the sector address
        call    #sd_read

sd_finish
        call    #sd_release
        wrlong  sdError, pvmaddr        ' Return error status
        jmp     #waitcmd

sd_read call    #sd_select
        mov     sdOp, #CMD17_READ_SINGLE_BLOCK
_readRepeat
        mov     sdParam, vmaddr
        call    #sdSectorCmd            ' Read from specified block
        call    #sdResponse
        mov     sdBlkCnt, sdBlkSize     ' Transfer a block at a time
_getRead
        call    #spiRecvByte
        tjz     count, #_skipStore      ' Check for count exhausted
        wrbyte  data, hubaddr
        add     hubaddr, #1
        sub     count, #1
_skipStore
        djnz    sdBlkCnt, #_getRead     ' Are we done with the block?
        call    #spiRecvByte
        call    #spiRecvByte            ' Yes, finish with 16 clocks
        add     vmaddr, #1
        tjnz    count, #_readRepeat     ' Check for more blocks to do
sd_read_ret
        ret

sd_write_handler
        mov     sdError, #0             ' Assume no errors
        rdlong  hubaddr, vmaddr         ' Get the buffer pointer
        add     vmaddr, #4
        rdlong  count, vmaddr wz        ' Get the byte count
  if_z  jmp     #sd_finish
        add     vmaddr, #4
        rdlong  vmaddr, vmaddr          ' Get the sector address
        call    #sd_select
        mov     sdOp, #CMD24_WRITE_BLOCK
_writeRepeat
        mov     sdParam, vmaddr
        call    #sdSectorCmd            ' Write to specified block
        mov     data, #$fe              ' Ask to start data transfer
        call    #spiSendByte
        mov     sdBlkCnt, sdBlkSize     ' Transfer a block at a time
_putWrite
        mov     data, #0                '  padding with zeroes if needed
        tjz     count, #_padWrite       ' Check for count exhausted
        rdbyte  data, hubaddr           ' If not, get the next data byte
        add     hubaddr, #1
        sub     count, #1
_padWrite
        call    #spiSendByte
        djnz    sdBlkCnt, #_putWrite    ' Are we done with the block?
        call    #spiRecvByte
        call    #spiRecvByte            ' Yes, finish with 16 clocks
        call    #sdResponse
        and     data, #$1f              ' Check the response status
        cmp     data, #5 wz             ' Must be Data Accepted
  if_ne mov     sdError, #1             ' Error: Write Error to SD Card
  if_ne jmp     #sd_finish
        movs    sdWaitData, #0          ' Wait until not busy
        call    #sdWaitBusy
        add     vmaddr, #1
        tjnz    count, #_writeRepeat    ' Check for more blocks to do
        jmp     #sd_finish

'------------------------------------------------------------------------------
' Send Sector Read/Write Command to SD Card
'------------------------------------------------------------------------------

sdSectorCmd
        shl     sdParam, adrShift       ' SD/MMC card uses byte address, SDHC uses sector address
sdSendCmd
        call    #spiRecvLong            ' Flush any previous command results
        mov     data, sdOp
        call    #spiSendByte
        mov     data, sdParam
        call    #spiSendLong
        mov     data, sdCRC             ' CRC code
        call    #spiSendByte
sdResponse
        movs    sdWaitData, #$ff        ' Wait for response from card
sdWaitBusy
        mov     sdTime, cnt             ' Set up a 1 second timeout
sdWaitLoop
        call    #spiRecvByte
        mov     t1, cnt
        sub     t1, sdTime              ' Check for expired timeout (1 sec)
        cmp     t1, sdFreq wc
  if_nc mov     sdError, #2             ' Error: SD Command timed out after 1 second
  if_nc jmp     #sd_finish
sdWaitData
        cmp     data, #0-0 wz           ' Wait for some other response
  if_e  jmp     #sdWaitLoop             '  than that specified
sdSectorCmd_ret
sdSendCmd_ret
sdResponse_ret
sdWaitBusy_ret
        ret

'----------------------------------------------------------------------------------------------------
' SPI Bus Access
'----------------------------------------------------------------------------------------------------

sd_select                           ' Single-SPI and Parallel-DeMUX
        andn    outa, mask_inc
        or      outa, select_addr
        andn    outa, cs_clr
sd_select_ret
        ret

sd_release                          ' Single-SPI and Parallel-DeMUX
        or      outa, cs_clr
        andn    outa, mask_inc
sd_release_ret
        ret

c3_sd_select_jmp                    ' Serial-DeMUX Jumps
        jmp     #c3_sd_select       ' Initialization copies these jumps
c3_sd_release_jmp                   '   over sd_select and sd_release
        jmp     #c3_sd_release      '   when in C3 mode.

c3_sd_select                        ' Serial-DeMUX
        mov     t1, select_addr
        andn    outa, cs_clr
        or      outa, cs_clr
_loop   or      outa, mask_inc
        andn    outa, mask_inc
        djnz    t1, #_loop
        jmp     sd_select_ret

c3_sd_release                       ' Serial-DeMUX
        andn    outa, cs_clr
        or      outa, cs_clr
        jmp     sd_release_ret

'----------------------------------------------------------------------------------------------------
' Low-level SPI routines
'----------------------------------------------------------------------------------------------------

spiSendLong
        mov     bits, #32
        jmp     #spiSend
spiSendByte
        shl     data, #24
        mov     bits, #8
spiSend andn    outa, sck_mask
        rol     data, #1 wc
        muxc    outa, mosi_mask
        or      outa, sck_mask
        djnz    bits, #spiSend
        andn    outa, sck_mask
        or      outa, mosi_mask
spiSendLong_ret
spiSendByte_ret
        ret

spiRecvLong
        mov     bits, #32
        jmp     #spiRecv
spiRecvByte
        mov     bits, #8
spiRecv mov     data, #0
_rloop  or      outa, sck_mask
        test    miso_mask, ina wc
        rcl     data, #1
        andn    outa, sck_mask
        djnz    bits, #_rloop
spiRecvLong_ret
spiRecvByte_ret
        ret

'----------------------------------------------------------------------------------------------------
' Data for the SD Card Routines
'----------------------------------------------------------------------------------------------------

sdOp            long    0
sdParam         long    0
sdParam1        long    0
sdCRC           long    0
sdCRC1          long    0
sdFreq          long    0
sdTime          long    0
sdError         long    0
sdBlkCnt        long    0
sdInitCnt       long    32768 / 8      ' Initial SPI clocks produced
sdBlkSize       long    512            ' Number of bytes in an SD block

adrShift        long    9       ' Number of bits to left shift SD sector address (9 for SD/MMC, 0 for SDHC)
sd3_3V          long    $1AA    ' Tell card we want to work at 3.3V
ccsbit          long    (1<<30) ' Flag to indicates SDHC/SDXC card

' Pointers to mailbox entries
pvmcmd          long    0       ' The address of the call parameter:
                                '     the virtual address and read/write bit, or the extended command
pvmaddr         long    0       ' The address of the call return:
                                '     the address of the cache line containing the virtual address, or the extended command error
vmline          long    0       ' line containing the virtual address, or the extended comand

zero            long    0       ' zero constant
t1              long    0       ' Temporary variable

spidir          long    0       ' Saved DIRA for the SPI bus

mosi_mask       long    0
miso_mask       long    0
sck_mask        long    0

cs_clr          long    0
mask_inc        long    0
select_addr     long    0

' Input parameters to block read/write
vmaddr          long    0       ' Pointer to the read/write parameters: buffer, count, sector, then during the reads the sector

' Temporaries used by block read/write
hubaddr         long    0       ' The block read/write buffer pointer
count           long    0       ' The block count

' Temporaries used by send/recv
bits            long    0       ' # bits to send/receive
data            long    0       ' Current data being sent/received

        fit     496
