/*
 * xae1000.xc
 *
 *  Created on: 14 Jun 2014
 *      Author: shabaz
 */

#include <xs1.h>
#include <string.h>
#include "spi_slave.h"
#include <stdio.h>
#include <platform.h>

#define ADC_TRIG_DELAY  40 //400ns minimum high/low time for ADC trigger signal
#define ADC_TRIG_PORT XS1_PORT_1A //ADC trigger pin. Defined by startKIT hardware
//#define LOOP_PERIOD     20000000    //Trigger ADC and print results every 200ms
//#define LOOP_PERIOD     (500*1E5)    //Trigger ADC and print results every 1000ms
#define LOOP_PERIOD     1000000    //Trigger ADC and print results every 10ms
#define STATEMAX 2
#define MAXSAMP 500

// tags
#define RETRIEVE 0x03
#define TIMEBASE 0x04
#define TRIGLEVEL 0x06
#define TRIGTYPE 0x08
#define TRIGSWEEP 0x0a

//trigger/trace settings
#define TRIG_RISING 0
#define TRIG_FALLING 1
#define SWEEP_CONT 0
#define SWEEP_NORM 1
#define SWEEP_SINGLE 2

// trigger state
#define WAIT 0
#define TRIGGERED 1

// 50 samples per div, these values are periods in microseconds per sample,
// to map to timebase settings of 50usec/div up to 100msec/dev
const unsigned int timebase_map[]={1, 2, 4, 10, 20, 40, 100, 200, 400, 1000, 2000};

//ADC Methods
typedef interface adc {
//Initiates a trigger sequence. If trigger already in progress, this call is ignored
  [[guarded]] void trigger(void);
//Reads the 4 ADC values and places them in array of unsigned shorts passed.
//Value is 0 to 65520 unsigned. Actual ADC is 12b so bottom 4 bits always zero. Ie. left justified
//Optionally returns the ADC state - 1 if ADC trigger/aquisition complete, or 0 if in progress
  [[clears_notification]] unsigned char* movable read(unsigned char* movable abufp);
//Call to client to indicate aquisition complete. Behaves a bit like ADC finish interrupt. Optional.
  [[notification]]  slave void complete(void);
  void set_period(unsigned int period);
  void set_triglevel(int lv);
  void set_dir(unsigned char dir);
  void set_sweepmode(unsigned char sm);
} startkit_adc_if;

[[combinable]]
//Runs ADC task. Very low MIPS consumption so is good candidate for combining with other low speed tasks
//Pass i_adc control inteface and automatic trigger period in microseconds.
//If trigger period is set to zero, ADC will only convert on trigger() call.
void adc_task(server startkit_adc_if i_adc, chanend c_adc, unsigned int trigger_period);


spi_slave_interface spi_sif =
{
    XS1_CLKBLK_3,
    XS1_PORT_1B, // SS
    XS1_PORT_1E, // MOSI
    XS1_PORT_1D, // MISO
    XS1_PORT_1C  // SCLK
};

// SS pin on PORT_32A is on pin P32A1, which is 0x02 bitmask
#define SS_BITMASK 0x02
#define BUFLEN 4096

port ss_port=XS1_PORT_32A;


// clock unused currently
clock clk = XS1_CLKBLK_1;

// codes
#define OK 1
#define NOK 2
#define SEND 3

interface to_rpi
{
    void array_data(unsigned char val[BUFLEN+3]);
    void code(unsigned char c);
};

interface from_rpi
{
    unsigned char* movable array_data(unsigned char* movable bufp);
    void code(unsigned char c);
};

interface adc_data
{
    [[notification]] slave void data_ready(void);
    [[clears_notification]] unsigned int* movable get_data(unsigned int* movable adcp);
};

out port adc_sample = ADC_TRIG_PORT;            //Trigger port for ADC - defined in STARTKIT.xn

#pragma select handler                          //Special function to allow select on inuint primative
void get_adc_data(chanend c_adc, unsigned &data){
    data = inuint(c_adc);                       //Get ADC packet one (2 x 16b samps)
}

static void init_adc_network(void) {
     unsigned data;

     read_node_config_reg(tile[0], 0x87, data);
     if (data == 0) {                                       //If link not setup already then...
         write_node_config_reg(tile[0], 0x85, 0xC0002004);  //open
         write_node_config_reg(tile[0], 0x85, 0xC1002004);  //and say hello
         write_sswitch_reg_no_ack(0x8000, 0x86, 0xC1002004);//say hello
         write_sswitch_reg_no_ack(0x8000, 0xC, 0x11111111); //Setup link directions
     }
}

static void init_adc_periph(chanend c) { //Configures the ADC peripheral for this application
     unsigned data[1], time;

     data[0] = 0x0;                               //Switch ADC off initially
     write_periph_32(adc_tile, 2, 0x20, 1, data);
     asm("add %0,%1,0":"=r"(data[0]):"r"(c));     //Get node/channel ID. Used for enable (below)
     data[0] &= 0xffffff00;                       //Mask off all but node/channel ID
     data[0] |= 0x1;                              //Set enable bit

     write_periph_32(adc_tile, 2, 0x0, 1, data);  //Enable Ch 0

     data[0] &= 0xffffff00;                              //Disable
     write_periph_32(adc_tile, 2, 0x4, 1, data);  //Disable Ch 1
     write_periph_32(adc_tile, 2, 0x8, 1, data);  //Disable Ch 2
     write_periph_32(adc_tile, 2, 0xc, 1, data);  //Disable Ch 3

     data[0] = 0x30101;  //32 bits per sample, 1 sample per 32b packet, calibrate off, ADC on
     write_periph_32(adc_tile, 2, 0x20, 1, data);

     time = 0;
     adc_sample <: 0 @ time;       //Ensure trigger startes low. Grab timestamp into time

     for (int i = 0; i < 6; i++) { //Do initial triggers. Do 6 calibrate and initialise
       time += ADC_TRIG_DELAY;
       adc_sample @ time <: 1;     //Rising edge triggers ADC
       time += ADC_TRIG_DELAY;
       adc_sample @ time <: 0;     //Falling edge
     }
     time += ADC_TRIG_DELAY;
     adc_sample @ time <: 0;       //Final delay to ensure 0 is asserted for minimum period
}



[[combinable]]
void adc_task(server startkit_adc_if i_adc, chanend c_adc, unsigned int trigger_period){
  unsigned adc_state = 0;                 //State machine. 0 = idle, 1-8 = generating triggers, 9 = rx data
  unsigned adc_samps[2] = {0, 0};         //The samples (2 lots of 16 bits packed into to unsigned ints)
  int trig_pulse_time;                    //Used to time individual edges for trigger
  int trig_period_time;                   //Used to time periodic triggers
  timer t_trig_state;                     //Timer for ADC trigger I/O pulse gen
  timer t_trig_periodic;                  //Timer for periodic ADC trigger
  int skip=0;
  int scount=0;

  // trigger and sweep settings
  int meas;
  int triglevel=2048; // 1.65V
  int normalised=0;
  unsigned char trigdir=TRIG_RISING;
  unsigned char sweepmode=SWEEP_CONT;
  int trigstate=WAIT; // this only applies to normal or single trigger modes, not to continuous mode



  int bufpos=0;
  int i;
  int runsweep=0;
  int oldlevel=0; // sample history
  unsigned char buf[MAXSAMP*2];

  init_adc_network();                     //Ensure it works in flash as well as run/debug
  init_adc_periph(c_adc);                 //Setup the ADC

  trigger_period *= 100;                  //Comvert to microseconds

  if(trigger_period){
      t_trig_periodic :> trig_period_time;//Get current time. Will cause immediate trigger
  }


  while(1){
    select{
      case i_adc.trigger():               //Start ADC state machine via interface method call
        if (adc_state == 0){
          adc_sample <: 1;                //Send first rising edge to trigger ADC
          t_trig_state :> trig_pulse_time;//Grab current time
          trig_pulse_time += ADC_TRIG_DELAY;//Setup trigger time for next edge (falling)
          adc_state = 1;                  //Start trigger state machine
        }
        else ;                            //Do nothing - trig/aquisition already in progress
      break;

                                          //Start ADC state machine via timer, if enabled
      case trigger_period => t_trig_periodic when timerafter(trig_period_time) :> void:
        trig_period_time += trigger_period;//Setup next trigger event
        if (adc_state == 0){              //Start tigger state machine
          adc_sample <: 1;                //Send first rising edge to trigger ADC
          t_trig_state :> trig_pulse_time;//Grab current time
          trig_pulse_time += ADC_TRIG_DELAY;//Setup trigger time for next edge (falling)
          adc_state = 1;                  //Start trigger state machine
        }
        else ;                            //Do nothing - trig/aquisition already in progress
        break;

                                          //I/O edge generation phase of ADC state machine
      case (adc_state > 0 && adc_state < STATEMAX) => t_trig_state when timerafter(trig_pulse_time) :> void:
        adc_state++;
        if (adc_state == STATEMAX){              //Assert low when finished
          adc_sample <: 0;
          break;
        }
        if (adc_state & 0b0001) adc_sample <: 1;  //Do rising edge if even count
        else adc_sample <: 0;                     //Do falling if odd
        trig_pulse_time += ADC_TRIG_DELAY;        //Setup next edge time trigger
        break;

                                            //Get ADC samples from packet phase of ADC state machine
      case (adc_state == STATEMAX) => get_adc_data(c_adc, adc_samps[0]): //Get ADC packet
        if (bufpos==0)
        {
            runsweep=0;
            if (sweepmode==SWEEP_CONT)
            {
                runsweep=1;
            }
            else if (((sweepmode==SWEEP_SINGLE) && (trigstate==WAIT))
                    || (sweepmode==SWEEP_NORM))
            {
                // check if the trigger has occurred
                if (trigdir==TRIG_RISING)
                {
                    if ((oldlevel<=triglevel) && ((adc_samps[0]>>20)>triglevel+1))
                    {
                        trigstate=TRIGGERED;
                        runsweep=1;
                    }
                }
                else // TRIG_FALLING
                {
                    if ((oldlevel>=triglevel) && ((adc_samps[0]>>20)<triglevel-1))
                    {
                        trigstate=TRIGGERED;
                        runsweep=1;
                    }
                }
            }

        }// end if (bufpos==0)

        // store the history
        meas=adc_samps[0]>>20;
        if ((bufpos==0) && (normalised==0))
        {
            oldlevel=meas;
            normalised=1;
        }
        else
        {
            if (trigdir==TRIG_RISING)
            {
                if (meas<oldlevel)
                    oldlevel=meas;
            }
            else // TRIG_FALLING
            {
                if (meas>oldlevel)
                    oldlevel=meas;
            }
        }
        // handle slow time base
        if (skip>0)
        {
            scount++;
            if (scount>skip)
            {
                scount=0;
            }
            else
            {
                // abort, don't count this sample
                chkct(c_adc, 1);                    //Wait for end token on ADC channel
                adc_state = 0;
                break;
            }
        }

        if ((bufpos<=(MAXSAMP*2-2)) && (runsweep==1))
        {
            //test
            //if (bufpos<50)
            //    adc_samps[0]=triglevel<<20;

            buf[bufpos]=adc_samps[0] >> 28; // most significant bits of ADC value
            buf[bufpos+1]=(adc_samps[0] >> 20) & 0xff; // LSB

            bufpos=bufpos+2;
        }
        chkct(c_adc, 1);                    //Wait for end token on ADC channel
        if (bufpos>=(MAXSAMP*2))
        {
            normalised=0;
            i_adc.complete();                   //Signal to client we're ready
        }
        adc_state = 0;                      //Reset tigger state machine
        break;

                                            //Provide ADC samples to client method
      case i_adc.read(unsigned char* movable abufp) -> unsigned char* movable abufq:
        for (i=0; i<=(MAXSAMP*2-2); i=i+2)
        {
            abufp[i+3]=buf[i];
            abufp[i+4]=buf[i+1];
        }
        abufq=move(abufp);

        // now we're ready to capture the trace again
        bufpos=0;
      break;

      case i_adc.set_period(unsigned int period):
        int p=period;
        if (period>20)
        {
            if (period==40)
                skip=1;
            else if (period=100)
                skip=4;
            else if (period==200)
                skip=9;
            else if (period==400)
                skip=19;
            else if (period==1000)
                skip=49;
            else if (period==2000)
                skip=99;
            p=20;
        }
        else
        {
            skip=0;
        }
        scount=0;
        trigger_period=100*p;
        normalised=0;
        bufpos=0; // restart a sweep capture
      break;

      case i_adc.set_triglevel(int lv):
        triglevel=lv;
        printf("tl %d\n", triglevel);
        normalised=0;
        bufpos=0; // restart a sweep capture
      break;

      case i_adc.set_dir(unsigned char dir):
        trigdir=dir;
        if (trigdir==TRIG_RISING)
        {
            oldlevel=0;
        }
        else
        {
            oldlevel=4096;
        }
        normalised=0;
        bufpos=0; // restart a sweep capture
      break;

      case i_adc.set_sweepmode(unsigned char sm):
        sweepmode=sm;
        printf("tm %d\n", sweepmode);
        if (sweepmode==SWEEP_CONT)
            trigstate=TRIGGERED;
        else
            trigstate=WAIT;

        normalised=0;
        bufpos=0; // restart a sweep capture
      break;

    }// end select
  }//end while(1)
}

void
spi_process(interface to_rpi server s, interface from_rpi client c)
{
    int pval;
    unsigned int len;
    unsigned char buffer_valid=0;
    unsigned char tosend=0;
    unsigned char bufa[BUFLEN+3];

    unsigned char* movable buf=bufa;
    unsigned char sbuf[16];

#ifdef junk
// ***********
unsigned start_time, end_time;
timer t;
while(1)
{
    t :> start_time;
    end_time = start_time + 100000;
    t when timerafter(end_time) :> void;
}
// ***********
#endif

    spi_slave_init(spi_sif);
    ss_port :> void;

    while(1)
    {
        // find state of PORT_32A
        ss_port :> pval; // get current port values
        if (pval & SS_BITMASK) // SS is high, i.e. deselected
        {
            // nothing to do
        }
        else
        {
            pval &= ~SS_BITMASK;
        }

        select
        {
            case ss_port when pinsneq(pval) :> int portval:
                if (portval & SS_BITMASK) // SS is high, i.e. deselected
                {
                    // data transfer is either complete, or aborted
                    // we don't check. Leave it to any higher level
                    // protocol to figure out.
                }
                else
                {
                    // SS is low, i.e. selected
                    // do we have any data to send?
                    if (buffer_valid && tosend)
                    {
                        //printf("tx\n");
                        //printf("tx SPI buf[0] is %02x, %02x, %02x, %02x, %02x, %02x\n", buf[0], buf[1], buf[2], buf[3], buf[4], buf[5]);
                        len=(((unsigned int)buf[1])<<8) | ((unsigned int)buf[2]);
                        spi_slave_out_buffer(spi_sif, buf, len+3);
                        buffer_valid=0;
                        tosend=0;
                        //c.code(OK);
                    }
                    else if (tosend)
                    {
                        // we were to send, but we don't have data yet
                        // (for example not triggered yet)
                        // in this case, we send back a special response
                        sbuf[0]=0x80;
                        sbuf[1]=0x00;
                        sbuf[2]=0x01;
                        sbuf[3]=0x99;
                        spi_slave_out_buffer(spi_sif, sbuf, 4);
                        buffer_valid=0;
                        tosend=0;
                    }
                    else
                    {
                        // if we're not sending then we're receiving
                        if (buf==NULL)
                            printf("buf is NULL!\n");
                        spi_slave_in_buffer(spi_sif, buf, BUFLEN+3);
                        //printf("in_buffer executed, from buf[0] is %02x, %02x, %02x, %02x, %02x, %02x\n", buf[0], buf[1], buf[2], buf[3], buf[4], buf[5]);
                        // is it an instruction for us to send data back
                        // to the RPI later?
                        if (buf[0] & 0x01) // LSB set indicates the RPI wants a response
                        {
                            tosend=1;
                        }
                        buffer_valid=0; // buffer contains data from RPI, not data valid for sending to RPI
                        buf=c.array_data(move(buf));
                      //  if (buf[0]==0x51)
                      //  {
                      //      //printf("error!");
                      //  }
                      //  if (buf==NULL)
                      //  {
                      //      //printf("Null!!!\n");
                      //  }
                    }
                    //printf("buffer_valid=%d, tosend=%d\n", buffer_valid, tosend);
                    //printf("Now from buf[0] is %02x, %02x, %02x, %02x, %02x, %02x, %02x\n", buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6]);

                }
                break;
            case s.code(unsigned char c):
                if (c==SEND)
                {
                    // ok we should send out the buffer contents to the RPI
                    buffer_valid=1;
                    //printf("send here!! buffer_valid=%d, tosend=%d\n", buffer_valid, tosend);
                }
                break;
            case s.array_data(unsigned char v[BUFLEN+3]):
                // ok we have received data to send to RPI.
                // we store it, until SS goes low
                //printf("s.array_data!\n");
                len=(((unsigned int)v[1])<<8) | ((unsigned int)v[2]);
                memcpy(buf, v, len*sizeof(char));
                buffer_valid=1;
                //printf("s.array_data buffer_valid=%d, tosend=%d\n", buffer_valid, tosend);
                break;
        } // end select
    } // end while(1)
}

void app(interface to_rpi client c, interface from_rpi server s, client startkit_adc_if i_adc)
{
  timer t_loop;                 //Loop timer
  int loop_time;                //Loop time comparison variable
  int tosend=0;
  int complete=0;
  int lv;

  printf("App started\n");

  t_loop :> loop_time;          //Take the initial timestamp of the 100Mhz timer
  loop_time += LOOP_PERIOD;     //Set comparison to future time
  while (1)
  {
    select
    {
                                //Loop timeout event
    case t_loop when timerafter(loop_time) :> void:
      //printf("fire\n");
      //if (i<MAXSAMP)
      //    i_adc.trigger();          //Fire the ADC!
      //i++;
      loop_time += LOOP_PERIOD; //Setup future time event
      break;

    case i_adc.complete():      //Notification from ADC server when aquisition complete
        // we won't read the data until we need to send it
        complete=1;
        //printf("sweep complete\n");
        break;

    case s.array_data(unsigned char* movable vp) -> unsigned char* movable vq:
        //printf("incoming SPI\n");
        if (vp[0]==RETRIEVE)  // retrieve samples
        {
            //printf("retrieve samples\n");
            if (complete)
            {
                //printf("retrieve valid\n");
                vp=i_adc.read(move(vp));
                vp[0]=0x83;
                //vp[1]=0x0f; // decimal 4000 high bits
                //vp[2]=0xa0; // decimal 4000 low byte
                vp[1]=(((MAXSAMP*2)>>8) & 0xff);
                vp[2]=(MAXSAMP*2) & 0xff;
                vq=move(vp);
                tosend=1;
                complete=0;
            }
            else
            {
                // we don't have a sweep to supply. Probably in single shot or normal mode
                // hand back the pointer
                vp[0]=0x80;
                vp[1]=0x00;
                vp[2]=0x01;
                vp[3]=0xaa;
                vq=move(vp);
            }
        }
        else if (vp[0]==TIMEBASE)
        {
            printf("TB %d\n", vp[3]);
            i_adc.set_period(timebase_map[vp[3]]);
            vq=move(vp);
        }
        else if (vp[0]==TRIGLEVEL)
        {
            lv=((int)vp[3])<<4;
            printf("TL %d\n", lv);
            i_adc.set_triglevel(lv);
            vq=move(vp);
        }
        else if (vp[0]==TRIGTYPE)
        {
            lv=vp[3];
            printf("TT %d\n", lv);
            i_adc.set_dir(lv); // 0=rising, 1=falling
            vq=move(vp);
        }
        else if (vp[0]==TRIGSWEEP)
        {
            lv=vp[3];
            printf("TM %d\n", lv);
            i_adc.set_sweepmode(lv); // 0=continuous, 1=normal, 2=single
            vq=move(vp);
        }
        else if (vp[0]==0)
        {
            // do nothing, ignore
            vq=move(vp);
        }
        else
        {
            // catch remainder possibilities
            // and do nothing
            vq=move(vp);
        }
        break;

    case s.code(unsigned char code):
        //printf("code message\n");
        break;
    }// end select

    if (tosend)
    {
        c.code(SEND);
        tosend=0;
    }
  }// end while (1)
}

int
main(void)
{
    interface to_rpi t;
    interface from_rpi f;
    startkit_adc_if i_adc;  //For triggering/reading ADC
    chan c_adc;             //Used by ADC driver to connect to ADC hardware

 //   ss_port :> void;

    par
    {
        on tile[0].core[0]:adc_task(i_adc, c_adc, 1);
        startkit_adc(c_adc);
        on tile[0]:spi_process(t, f);
        on tile[0]:app(t, f, i_adc);

    }

    return(0);
}


