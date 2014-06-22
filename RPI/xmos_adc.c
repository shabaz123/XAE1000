/******************************************************
 * xmos_adc.c
 * SPI interface to XMOS startKIT
 * 
 * rev. 1 - Initial version - shabaz
 *
 * Based on spidev.c, this code implements
 * a TLV (tag,length, value) protocol
 * to control data flow between the 
 * Linux platform (e.g. Raspberry Pi) and
 * the XMOS startKIT board in both directions.
 * The code here is used to retrieve measurements
 * from an ADC
 ******************************************************/

#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include <linux/spi/spidev.h>
#include <unistd.h> // sleep
#include <time.h>

typedef struct spi_ioc_transfer spi_t;
extern int errno;
static const char *device = "/dev/spidev0.1";

int
delay_ms(unsigned int msec)
{
  int ret;
  struct timespec a;
  if (msec>999)
  {
    //fprintf(stderr, "delay_ms error: delay value needs to be less than 999\n");
    msec=999;
  }
  a.tv_nsec=((long)(msec))*1E6d;
  a.tv_sec=0;
  if ((ret = nanosleep(&a, NULL)) != 0)
  {
    //fprintf(stderr, "delay_ms error: %s\n", strerror(errno));
  }
  return(0);
}

int
main(int argc, char* argv[])
{
	int fd;
	int ret;
	int i;
	int nb;
	unsigned int cmd=0;
	unsigned int level=0;
	uint8_t spi_config=0;
	uint8_t spi_bits=8;
	uint32_t spi_speed; //=32768;
	spi_speed=32768000; // this can take a few specific values
	
	
	spi_speed=1310720; // we have some longer wiring
	spi_t spi;
	unsigned char txbuf[4099];
	unsigned char rxbuf[4099];
	int j;
	unsigned int servo[8];
	
	if (argc>1)
	{
		sscanf(argv[1], "%d", &cmd);
	}
	if (argc>2)
	{
		sscanf(argv[2], "%d", &level);
	}
	//printf("cmd is %d\n", cmd);
	
	//fprintf(stderr, "Hello stderr from app\n");
	//fprintf(stdout, "Hello stdout from app\n");
	//printf("Hello printf from app\n");
	
	fd=open(device, O_RDWR);
	if (fd<0)
	{
		fprintf(stderr, "Error opening device: %s\n", strerror(errno));
		exit(1);
  }
  
  //spi_config |= SPI_CS_HIGH;
  ret=ioctl(fd, SPI_IOC_WR_MODE, &spi_config);
  if (ret<0)
  {
  	fprintf(stderr, "Error setting SPI write mode: %s\n", strerror(errno));
		exit(1);
  }
  ret=ioctl(fd, SPI_IOC_RD_MODE, &spi_config);
  if (ret<0)
  {
  	fprintf(stderr, "Error setting SPI read mode: %s\n", strerror(errno));
		exit(1);
  }
  ret=ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &spi_bits);
  if (ret<0)
  {
  	fprintf(stderr, "Error setting SPI write bits: %s\n", strerror(errno));
		exit(1);
  }
  ret=ioctl(fd, SPI_IOC_RD_BITS_PER_WORD, &spi_bits);
  if (ret<0)
  {
  	fprintf(stderr, "Error setting SPI read bits: %s\n", strerror(errno));
		exit(1);
  }
  ret=ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &spi_speed);
  if (ret<0)
  {
  	fprintf(stderr, "Error setting SPI write speed: %s\n", strerror(errno));
		exit(1);
  }
  ret=ioctl(fd, SPI_IOC_RD_MAX_SPEED_HZ, &spi_speed);
  if (ret<0)
  {
  	fprintf(stderr, "Error setting SPI read speed: %s\n", strerror(errno));
		exit(1);
  }
  
  
  // clean receive buffer
  for (i=0; i<20; i++)
  {
  	rxbuf[i]=0;
  }
  
  // send to tag 0x03
  txbuf[0]=0x03;
  txbuf[1]=0x0f;
  txbuf[2]=0xa0;
  spi.len=4003;
  nb=4003;
  
  if (cmd==3) // request trace
  {
  	txbuf[0]=0x03;
  	txbuf[1]=0x00;
  	txbuf[2]=0x01;
  	spi.len=4;
  	nb=4;
	}
	else if (cmd==0) // retrieve trace
	{
		//delay_ms(99);
		txbuf[0]=0x00;
  	txbuf[1]=0x03;
  	txbuf[2]=0xe8;
  	spi.len=1003;
  	nb=1003;
  }
  else if (cmd==4) // set timebase
  {
  	txbuf[0]=0x04;
  	txbuf[1]=0x00;
  	txbuf[2]=0x01;
  	txbuf[3]=level;
  	spi.len=4;
  	nb=4;
	}
	else if (cmd==6) // set triglevel
  {
  	if (level>255)
  		level=255;
  	txbuf[0]=0x06;
  	txbuf[1]=0x00;
  	txbuf[2]=0x01;
  	txbuf[3]=level;
  	spi.len=4;
  	nb=4;
	}
	else if (cmd==8) // set trigdir
  {
  	txbuf[0]=0x08;
  	txbuf[1]=0x00;
  	txbuf[2]=0x01;
  	txbuf[3]=level;
  	spi.len=4;
  	nb=4;
	}
	else if (cmd==10) // set trigmode (cont/norm/single)
  {
  	txbuf[0]=0x0a;
  	txbuf[1]=0x00;
  	txbuf[2]=0x01;
  	txbuf[3]=level;
  	spi.len=4;
  	nb=4;
	}
  
  spi.delay_usecs=0;
  spi.speed_hz=spi_speed;
  spi.bits_per_word=spi_bits;
  spi.cs_change=0;
  spi.tx_buf=(unsigned long)txbuf;
  spi.rx_buf=(unsigned long)rxbuf;
  

  ret=ioctl(fd, SPI_IOC_MESSAGE(1), &spi);
  if (ret<0)
  {
  	fprintf(stderr, "Error performing SPI exchange: %s\n", strerror(errno));
		exit(1);
  }
  
  
  fprintf(stdout, "%02x", rxbuf[0]);
  for (i=1; i<(nb-3); i++)
  {
		fprintf(stdout, ",%02x", rxbuf[i]);
	}
	fprintf(stdout, "\n");
	
  close(fd);
  
  return(0);
}
