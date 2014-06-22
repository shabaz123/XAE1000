#!/usr/bin/env node

var app = require('http').createServer(handler)
  , io = require('socket.io').listen(app)
  , fs = require('fs')

app.listen(8081);

// variables
var child=require('child_process');
var prog;
var prog2;
var runscope=0;

var progpath='/home/pi/development/xae/';
var values = "abc";

// HTML handler
function handler (req, res)
{
	console.log('url is '+req.url.substr(1));
	reqfile=req.url.substr(1);
//	if (reqfile != "xmp-logo.png")
//	{
//		reqfile="index.html"; // only allow this file for now
//	}
	fs.readFile(progpath+reqfile,
  function (err, data)
  {
    if (err)
    {
      res.writeHead(500);
      return res.end('Error loading index.html');
    }
    res.writeHead(200);
    res.end(data);
  });
}

function xmos_adc(v)
{
	prog=child.exec(progpath+'xmos_servo '+v), function (error, data, stderr) {
	  values=data.toString();
	  console.log('old prog executed, values length is '+values.length);
	};
	prog.on('exit', function(code)
	{
		socket.emit('results', {measurement: values});
		console.log('old app complete, values length is '+values.length);
	});
	
}





// Socket.IO comms handling
// A bit over-the-top but we use some handshaking here
// We advertise message 'status stat:idle' to the browser once,
// and then wait for message 'action command:xyz'
// We handle the action xyz and then emit the message 'status stat:done'
io.sockets.on('connection', function (socket)
{
	socket.emit('status', {stat: 'ready'});
	
  socket.on('action', function (data)
  {
  	cmd=data.command;
    //console.log(cmd);
    issweep=0;
  	if (cmd=="sweep")
  	{
  		issweep=1;
  	}
  	
		if (issweep)
		{
			//
		}
		else
		{
			var temp = cmd.split(" ");
			if (temp[0]=="trigmode")
			{
				prog2=child.exec(progpath+'xmos_adc 10 '+temp[1], function (error, data, stderr){
				});
			}
			else if (temp[0]=="timebase")
			{
				prog2=child.exec(progpath+'xmos_adc 4 '+temp[1], function (error, data, stderr){
				});
			}
			else if (temp[0]=="trigdir")
			{
				prog2=child.exec(progpath+'xmos_adc 8 '+temp[1], function (error, data, stderr){
				})
			}
			else if (temp[0]=="triglevel")
			{
				prog2=child.exec(progpath+'xmos_adc 6 '+temp[1], function (error, data, stderr){
				})
			}
		}
		
		// we always execute this, because we need to flush out the previous capture
  		prog2=child.exec(progpath+'xmos_adc 3', function (error, data, stderr){
				//console.log('request complete, length is '+data.toString().length);
			});
	
			prog=child.exec(progpath+'xmos_adc 0', function (error, data, stderr) {
	  		values=data.toString();
	  		//console.log('retrieve complete, length is '+values.length);
	  		socket.emit('results', values);
			});
		
		
		// ret=handleCommand(cmd);
    // socket.emit('status', {stat: ret});


  }); // end of socket.on('action', function (data)

}); // end of io.sockets.on('connection', function (socket)


