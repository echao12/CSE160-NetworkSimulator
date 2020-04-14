
#include "../../includes/socket.h"

module TransportP{
    // provides shows the interface we are implementing. See lib/interface/Transport.nc
    // to see what funcitons we need to implement.
   provides interface Transport;
   uses interface List<socket_store_t> as socketList;
   uses interface Timer<TMilli> as listenTimer;
   uses interface Random;
   uses interface Hashmap<socket_t> as usedSockets;//mainly used to track available fd's. value of 1 is established connection
}


implementation{
    socket_t listenFd = NULL_SOCKET;

   /**
    * Get a socket if there is one available.
    * @Side Client/Server
    * @return
    *    socket_t - return a socket file descriptor which is a number
    *    associated with a socket. If you are unable to allocated
    *    a socket then return a NULL socket_t.
    */
   command socket_t Transport.socket(){
       //declare vars at top!
       socket_t fd = NULL_SOCKET; //should return NULL if unable to allocate.
       uint8_t temp = 1;
       //check socketList to see if it has room
       if(!call socketList.isFull()){
           // assign next available socket number
           while(call usedSockets.contains(temp)){
               temp++;
           }
           //temp is the free value
           dbg(TRANSPORT_CHANNEL, "Found available socket fd: (%hhu)\n", temp);
           call usedSockets.insert(temp, 0);//key tracks used socker fd's
           fd = temp;
           return fd;
       }
       dbg(TRANSPORT_CHANNEL, "FAILED TO ALLOCATE SOCKET FD\n");
       //socketList is full, cannot allocate a new socket fd
       return fd;
   }

   /**
    * Bind a socket with an address.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       you are binding.
    * @param
    *    socket_addr_t *addr: the source port and source address that
    *       you are biding to the socket, fd.
    * @Side Client/Server
    * @return error_t - SUCCESS if you were able to bind this socket, FAIL
    *       if you were unable to bind.
    */
   command error_t Transport.bind(socket_t fd, socket_addr_t *addr){
        //generate a new socket_store_t
        socket_store_t socketConfig;
        error_t error;
        dbg(TRANSPORT_CHANNEL, "Binding: fd(%hhu) to src_addr(P:%hhu / ID:%hhu)\n", fd, addr->port, addr->addr);
        if(fd != NULL_SOCKET && addr != NULL){
            socketConfig.src.port = addr->port;//i guess TOS_NODE_ID is address and already a given?
            socketConfig.src.addr = addr->addr;
            socketConfig.fd = fd;
            socketConfig.state = CLOSED;
            call socketList.pushback(socketConfig);//adding it to this node's socketlist
            dbg(TRANSPORT_CHANNEL, "SUCESSFULLY BOUNDED!\n");
            error = SUCCESS;
       }else{
            dbg(TRANSPORT_CHANNEL, "FAILED TO BIND!\n");
            error = FAIL;
       }
       return error;
   }

   /**
    * Checks to see if there are socket connections to connect to and
    * if there is one, connect to it.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that is attempting an accept. remember, only do on listen. 
    * @side Server
    * @return socket_t - returns a new socket if the connection is
    *    accepted. this socket is a copy of the server socket but with
    *    a destination associated with the destination address and port.
    *    if not return a null socket.
    */
   command socket_t Transport.accept(socket_t fd){}

   /**
    * Write to the socket from a buffer. This data will eventually be
    * transmitted through your TCP implimentation.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that is attempting a write.
    * @param
    *    uint8_t *buff: the buffer data that you are going to wrte from.
    * @param
    *    uint16_t bufflen: The amount of data that you are trying to
    *       submit.
    * @Side For your project, only client side. This could be both though.
    * @return uint16_t - return the amount of data you are able to write
    *    from the pass buffer. This may be shorter then bufflen
    */
   command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen){}

   /**
    * This will pass the packet so you can handle it internally. 
    * @param
    *    pack *package: the TCP packet that you are handling.
    * @Side Client/Server 
    * @return uint16_t - return SUCCESS if you are able to handle this
    *    packet or FAIL if there are errors.
    */
   command error_t Transport.receive(pack* package){}

   /**
    * Read from the socket and write this data to the buffer. This data
    * is obtained from your TCP implimentation.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that is attempting a read.
    * @param
    *    uint8_t *buff: the buffer that is being written.
    * @param
    *    uint16_t bufflen: the amount of data that can be written to the
    *       buffer.
    * @Side For your project, only server side. This could be both though.
    * @return uint16_t - return the amount of data you are able to read
    *    from the pass buffer. This may be shorter then bufflen
    */
   command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen){}

   /**
    * Attempts a connection to an address.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that you are attempting a connection with. 
    * @param
    *    socket_addr_t *addr: the destination address and port where
    *       you will atempt a connection.
    * @side Client
    * @return socket_t - returns SUCCESS if you are able to attempt
    *    a connection with the fd passed, else return FAIL.
    */
   command error_t Transport.connect(socket_t fd, socket_addr_t * addr){}

   /**
    * Closes the socket.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that you are closing. 
    * @side Client/Server
    * @return socket_t - returns SUCCESS if you are able to attempt
    *    a closure with the fd passed, else return FAIL.
    */
   command error_t Transport.close(socket_t fd){}

   /**
    * A hard close, which is not graceful. This portion is optional.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that you are hard closing. 
    * @side Client/Server
    * @return socket_t - returns SUCCESS if you are able to attempt
    *    a closure with the fd passed, else return FAIL.
    */
   command error_t Transport.release(socket_t fd){}

   /**
    * Listen to the socket and wait for a connection.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that you are hard closing. 
    * @side Server
    * @return error_t - returns SUCCESS if you are able change the state 
    *   to listen else FAIL.
    */
   command error_t Transport.listen(socket_t fd){
       socket_store_t socket;
       bool found = FALSE;
       error_t error;
       dbg(TRANSPORT_CHANNEL, "Attempting to listen to socket %hhu\n", fd);
       //will hard close fd...force change state w/o signaling the change??
       if(call usedSockets.contains(fd)){
           dbg(TRANSPORT_CHANNEL,"socket %hhu is in use, force closing...\n", fd);
           //force change socket state
           //first find it
           while(!found){
               socket = call socketList.front();
               if(socket.fd == fd){
                   dbg(TRANSPORT_CHANNEL,"FOUND socket %hhu in socketList to close...\n", fd);
                   //found it, change state and clear data
                   socket.state = LISTEN;
                   socket.dest.port = 0;
                   socket.dest.addr = 0;
                   //remove indicator of established connection
                   call usedSockets.set(fd, 0);
                   found = TRUE;
               }
               //not it
               call socketList.popfront();
               call socketList.pushback(socket);
           }
           dbg(TRANSPORT_CHANNEL,"Starting timer to listen for connections...\n");
           listenFd = fd;
           //will check for connection to accept every 5 seconds
           call listenTimer.startPeriodic(5000);
           error = SUCCESS;
           return error;
       }
       else{
           // Shouldn't we do nothing if the specified socket is not being used?
           dbg(TRANSPORT_CHANNEL, "Failed to listen to socket %hhu as it is not being used\n", fd);
           error = FAIL;
           return error;

        //    dbg(TRANSPORT_CHANNEL,"Socket %hhu is not in use. Looking for it in socketList..\n", fd);
        //    //not in usedSockets, fresh connection
        //    while(!found){
        //        socket = call socketList.front();
        //        if(socket.fd == fd){
        //            //found it, change state and clear data
        //            socket.state = LISTEN;
        //            found = TRUE;
        //            //dbg(TRANSPORT_CHANNEL,"FOUND and switched state to LISTEN...\n");
        //        }
        //        //not it
        //        call socketList.popfront();
        //        call socketList.pushback(socket);
        //    }
        //    dbg(TRANSPORT_CHANNEL,"Starting timer to listen for connections...\n");
        //    listenFd = fd;
        //    //will check for connection to accept every 5 seconds
        //    call listenTimer.startPeriodic(5000);
        //    error = SUCCESS;
        //    return error;
       }
       listenFd = NULL_SOCKET;
       dbg(TRANSPORT_CHANNEL,"Failed to listen to socket %hhu...\n", fd);
       error = FAIL;
       return error;
   }

   /*  TIMER FUNCTIONS */
   event void listenTimer.fired(){
       if(listenFd != NULL_SOCKET){
           //attempt to connect with the listening socket
           call Transport.accept(listenFd);
       }
   }
}
