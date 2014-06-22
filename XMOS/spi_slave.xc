// Copyright (c) 2011, XMOS Ltd., All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>

///////////////////////////////////////////////////////////////////////////////
//
// SPI Slave

#include <xs1.h>
#include <xclib.h>
#include <platform.h>
#include "spi_slave.h"
#include <stdio.h>

extern port ss_port;
unsigned char tbuf[3];
unsigned int len;
unsigned int count;

void spi_slave_init(spi_slave_interface &spi_if)
{

    int clk_start;
    set_clock_on(spi_if.blk);
    configure_clock_src(spi_if.blk, spi_if.sclk);
    configure_in_port(spi_if.mosi, spi_if.blk);
    configure_out_port(spi_if.miso, spi_if.blk, 0);
    start_clock(spi_if.blk);

    return;

}

void spi_slave_shutdown(spi_slave_interface &spi_if)
{
    stop_clock(spi_if.blk);

    set_clock_off(spi_if.blk);
    set_port_use_off(spi_if.ss);
    set_port_use_off(spi_if.mosi);
    set_port_use_off(spi_if.miso);
    set_port_use_off(spi_if.sclk);
}

unsigned char spi_slave_in_byte(spi_slave_interface &spi_if)
{
    // big endian byte order
    // MSb-first bit order
    unsigned int data;
    spi_if.mosi :> >> data;
    return bitrev(data);
}

unsigned short spi_slave_in_short(spi_slave_interface &spi_if)
{
    // big endian byte order
    // MSb-first bit order
    unsigned int data;
    spi_if.mosi :> >> data;
    spi_if.mosi :> >> data;
    return bitrev(data);
}

unsigned int spi_slave_in_word(spi_slave_interface &spi_if)
{
    // big endian byte order
    // MSb-first bit order
    unsigned int data;
    spi_if.mosi :> >> data;
    spi_if.mosi :> >> data;
    spi_if.mosi :> >> data;
    spi_if.mosi :> >> data;
    return bitrev(data);
}

#pragma unsafe arrays
void spi_slave_in_buffer(spi_slave_interface &spi_if, unsigned char buffer[], int num_bytes)
{
    unsigned int data;
    unsigned int vlen=0;

    clearbuf(spi_if.miso);
    clearbuf(spi_if.mosi);

    for (int i = 0; i < num_bytes; i++)
    {
        spi_if.mosi :> data;
        data=data<<24;
        buffer[i]=bitrev(data);
        if (i==2)
        {
            vlen=(((unsigned int)buffer[1])<<8) | (unsigned int)buffer[2];
            if (vlen==0)
                break;
        }
        if (i >= vlen+2)
        {
            break;
        }
    }
}

static inline void spi_slave_out_byte_internal(spi_slave_interface &spi_if, unsigned char data)
{
    // MSb-first bit order
    unsigned int data_rev = bitrev(data) >> 24;


//#if (SPI_SLAVE_MODE == 0 || SPI_SLAVE_MODE == 2) // modes where CPHA == 0
    // handle first bit
    asm("setc res[%0], 8" :: "r"(spi_if.miso)); // reset port
    spi_if.miso <: data_rev; // output first bit
    asm("setc res[%0], 8" :: "r"(spi_if.miso)); // reset port
    asm("setc res[%0], 0x200f" :: "r"(spi_if.miso)); // set to buffering
    asm("settw res[%0], %1" :: "r"(spi_if.miso), "r"(32)); // set transfer width to 32
    stop_clock(spi_if.blk);
    configure_clock_src(spi_if.blk, spi_if.sclk);
    configure_out_port(spi_if.miso, spi_if.blk, data_rev);
    start_clock(spi_if.blk);

    // output remaining data
    spi_if.miso <: (data_rev >> 1);
//#else
//    spi_if.miso <: data_rev;
//#endif


    if (count>2)
    {
        spi_if.mosi :> void;
    }
    else
    {
        spi_if.mosi :> tbuf[count];
        if (count==2)
        {
            len=(((unsigned int)tbuf[1])<<8) | ((unsigned int)tbuf[2]);
        }
    }
    count++;


}

void spi_slave_out_byte(spi_slave_interface &spi_if, unsigned char data)
{
    spi_slave_out_byte_internal(spi_if, data);
}

void spi_slave_out_short(spi_slave_interface &spi_if, unsigned short data)
{
    // big endian byte order
    spi_slave_out_byte_internal(spi_if,(data >> 8) & 0xFF);
    spi_slave_out_byte_internal(spi_if, data & 0xFF);
}

void spi_slave_out_word(spi_slave_interface &spi_if, unsigned int data)
{
    // big endian byte order
    spi_slave_out_byte_internal(spi_if, (data >> 24) & 0xFF);
    spi_slave_out_byte_internal(spi_if, (data >> 16) & 0xFF);
    spi_slave_out_byte_internal(spi_if, (data >> 8) & 0xFF);
    spi_slave_out_byte_internal(spi_if, data & 0xFF);
}

#pragma unsafe arrays
void spi_slave_out_buffer(spi_slave_interface &spi_if, const unsigned char buffer[], int num_bytes)
{
    clearbuf(spi_if.miso);
    clearbuf(spi_if.mosi);

    len=0;
    count=0;

    //printf("spi num_bytes out is %d\n", num_bytes);
    //printf("spi buf[0] is %02x, %02x, %02x, %02x\n", buffer[0], buffer[1], buffer[2], buffer[3]);
    for (int i = 0; i < num_bytes; i++)
    {
        spi_slave_out_byte_internal(spi_if, buffer[i]);
        if (i>=len+2)
            break;
    }
}
