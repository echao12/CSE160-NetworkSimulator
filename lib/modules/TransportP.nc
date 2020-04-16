
#include "../../includes/socket.h"

module TransportP{
    // provides shows the interface we are implementing. See lib/interface/Transport.nc
    // to see what funcitons we need to implement.
   provides interface Transport;
   uses interface List<socket_store_t> as socketList;
   uses interface Timer<TMilli> as listenTimer;
   uses interface Random;
   //track available sockets. value(0):open socket, value(1) established connection
   uses interface Hashmap<socket_t> as usedSockets;

   // track outstanding packets
   uses interface List<pack> as outstandingPackets;
   uses interface List<uint32_t> as timeToResend;
   uses interface Timer<TMilli> as resendTimer;
}


implementation{
   socket_t listenFd = NULL_SOCKET;
   pack sendPackage;
   tcp_pack TCPPackage;
   socket_t curSocketNumber;

   void makeOutstanding(pack Package, uint16_t timeoutValue);
   void acknowledgePacket(pack *Package);

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   void makeTCPPack(tcp_pack *Package, uint8_t srcPort, uint8_t destPort, uint16_t byteSeq, uint16_t acknowledgement, uint8_t flags, uint8_t advertisedWindow, uint8_t *payload, uint8_t length);
   void extractTCPPack(pack *Package, tcp_pack* TCPPack);

   socket_store_t* getSocketPtr(socket_t fd);

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
            call resendTimer.startOneShotAt(call resendTimer.getNow(), RTT_ESTIMATE);
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
   command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen){
        socket_store_t* socket;
        uint16_t i, num;
        
        // Get the specified socket
        socket = getSocketPtr(fd);

        if (socket == NULL) {
            // The specified socket doesn't exist
            // dbg(TRANSPORT_CHANNEL, "Error in Transport.write: Socket %hhu doesn't exist\n", fd);
            return 0;
        }
        else if (socket->state != ESTABLISHED) {
            // The specified socket doesn't have a connection yet
            // dbg(TRANSPORT_CHANNEL, "Error in Transport.write: Socket %hhu is not in ESTABLISHED state\n", fd);
            return 0;
        }

        // Use lastAck/lastWritten to calculate how much data to write to the buffer
        // For now, just make sure all the numbers can get here correctly
        dbg(TRANSPORT_CHANNEL, "Writing to sendBuff:\n");
        for (i = 0; i < bufflen; i += 2) {
            memcpy(&num, &buff[i], 2);
            dbg(TRANSPORT_CHANNEL, "%hhu\n", num);
        }
        dbg(TRANSPORT_CHANNEL, "Finished writing\n");

        return bufflen;
   }

   /**
    * This will pass the packet so you can handle it internally. 
    * @param
    *    pack *package: the TCP packet that you are handling.
    * @Side Client/Server 
    * @return uint16_t - return SUCCESS if you are able to handle this
    *    packet or FAIL if there are errors.
    */
   command error_t Transport.receive(pack* package){
       bool found = FALSE;
       int numAttempts = 0;
       socket_store_t socket;
       error_t error = FAIL;
       uint8_t windowSize = 1;

        dbg(TRANSPORT_CHANNEL, "Transport Module: \nNODE(%hhu) RECIEVED TCP Packet seq#(%hhu)\n", TOS_NODE_ID, package->seq);
        extractTCPPack(package, &TCPPackage);
        logTCPPack(&TCPPackage);

        //find the socket info
        while(found == FALSE && numAttempts < MAX_NUM_OF_SOCKETS){
            socket = call socketList.popfront();
            //dbg(TRANSPORT_CHANNEL,"CHECKING SOCKET VALUES:\nsocketAddr:%hhu, pkgDest:%hhu\nsocketPort:%hhu, pkgPort:%hhu\n",
            //socket.src.addr, package->dest, socket.src.port, TCPPackage.destPort);
            if(socket.src.addr == package->dest && socket.src.port == TCPPackage.destPort){
                dbg(TRANSPORT_CHANNEL,"FOUND SOCKET\n");
                found = TRUE;
            }else{
                call socketList.pushback(socket);
                numAttempts++;
            }
        }

        if (!found) {
            dbg(TRANSPORT_CHANNEL, "FAILED: Could not find corresponding socket for the packet.\n*DROPPED TCP PACKET!*\n");
            return FAIL;
        }

        dbg(TRANSPORT_CHANNEL, "Checking socket state...(STATE:%hhu)\n", socket.state);
        //LISTEN
        if(socket.state == LISTEN){
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: LISTENING...\n");
            //check for a SYN msg
            if(checkFlagBit(&TCPPackage, SYN_FLAG_BIT)){
                dbg(TRANSPORT_CHANNEL, "RECEIVED SYN PACKET(sender seq#: %hhu)\nREPLYING with SYN/ACK TCP Packet\n", package->seq);
                //record packet source as this port's destination
                socket.dest.addr = package->src;
                socket.dest.port = TCPPackage.srcPort;
                //record sequence#
                socket.lastRcvd = TCPPackage.byteSeq;
                socket.nextExpected = TCPPackage.byteSeq + 1;
                //socket.nextExpected = TCPPackage.byteSeq + 1;
                //generate SYN packet with ack, recall 4th argument is byteSeq;
                makeTCPPack(&TCPPackage, socket.src.port, socket.dest.port, 0, socket.nextExpected, 0, 0, "SYN_REPLY", TCP_PACKET_MAX_PAYLOAD_SIZE);
                setFlagBit(&TCPPackage, SYN_FLAG_BIT);
                setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                makePack(&sendPackage, socket.src.addr, socket.dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                
                if (signal Transport.send(&sendPackage) == SUCCESS) {
                    makeOutstanding(sendPackage, RTT_ESTIMATE);
                    socket.state = SYN_RCVD;
                    socket.lastSent = TCPPackage.byteSeq;//not too sure yet.
                    error = SUCCESS;
                }
            }
        }
        //STATE: SYN_SENT, check to see if we got syn/ack packet.
        else if (socket.state == SYN_SENT) {
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: SYN_SENT\n");
            // Check for SYN+ACK packet
            if (checkFlagBit(&TCPPackage, SYN_FLAG_BIT) && checkFlagBit(&TCPPackage, ACK_FLAG_BIT)) {
                //the packet's ACK value is the expecting value
                dbg(TRANSPORT_CHANNEL, "RECEIVED SYN+ACK PACKET\nREPLYING with ACK TCP Packet\n");
                socket.lastAck = TCPPackage.acknowledgement - 1;//(NOT SURE ABOUT THIS YET) i think it should be the packet's ack #
                socket.nextExpected = TCPPackage.byteSeq + 1;
                // Make ACK packet with reciever's byteSeq+1 val
                makeTCPPack(&TCPPackage, socket.src.port, socket.dest.port, socket.lastSent+1, socket.nextExpected, 0, 0, "ACK", TCP_PACKET_MAX_PAYLOAD_SIZE);
                setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                makePack(&sendPackage, socket.src.addr, socket.dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                if (signal Transport.send(&sendPackage) == SUCCESS) {
                    //update sender socket values
                    socket.lastSent++;
                    acknowledgePacket(package);
                    makeOutstanding(sendPackage, RTT_ESTIMATE);
                    socket.state = ESTABLISHED;
                    //adjust usedSocket value
                    call usedSockets.set(socket.fd, 1);
                    dbg(TRANSPORT_CHANNEL, "\nSOCKET[%hhu][%hhu]->[%hhu][%hhu] STATE IS NOW ESTABLISHED\n",
                    socket.src.addr, socket.src.port, socket.dest.addr, socket.dest.port);
                    error = SUCCESS;
                }
            }
        }
        //SYN_RCVD
        else if (socket.state == SYN_RCVD) {
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: SYN_RCVD\n");
            // Check for any ACK packet with proper seq#
            if (checkFlagBit(&TCPPackage, ACK_FLAG_BIT)) {
                dbg(TRANSPORT_CHANNEL, "RECEIVED ACK PACKET\n");
                socket.lastRcvd = TCPPackage.byteSeq;
                socket.nextExpected = TCPPackage.byteSeq + 1;
                socket.state = ESTABLISHED;  // Change state to ESTABLISHED no matter what
                //adjust usedSocket Map value
                call usedSockets.set(socket.fd, 1);//1 is established, 0 is not
                dbg(TRANSPORT_CHANNEL, "\nSOCKET[%hhu][%hhu]->[%hhu][%hhu] STATE IS NOW ESTABLISHED\n",
                    socket.src.addr, socket.src.port, socket.dest.addr, socket.dest.port);
                acknowledgePacket(package);
                //Send effective window
                //Send effective window to client
                dbg(TRANSPORT_CHANNEL, "Sending effective window size (%hhu)\n", windowSize);
                makeTCPPack(&TCPPackage, socket.src.port, socket.dest.port, socket.lastSent+1, socket.nextExpected, 0, windowSize, "Windowing...", TCP_PACKET_MAX_PAYLOAD_SIZE);
                TCPPackage.flags = 0;//reset flags
                setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                makePack(&sendPackage, socket.src.addr, socket.dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                if(signal Transport.send(&sendPackage) == SUCCESS){
                    makeOutstanding(sendPackage, RTT_ESTIMATE);
                    socket.lastSent++;
                }
            }
        }
        //ESTABLISHED
        else if (socket.state == ESTABLISHED) {
            //received a packet, update info
            socket.lastRcvd = TCPPackage.byteSeq;
            socket.nextExpected = TCPPackage.byteSeq + 1;
            acknowledgePacket(package);//packet received
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: ESTABLISHED\n");
            // Drop any SYN packet
            if (checkFlagBit(&TCPPackage, SYN_FLAG_BIT)) {
                // Do nothing
            }
            else if (checkFlagBit(&TCPPackage, ACK_FLAG_BIT)) {
                dbg(TRANSPORT_CHANNEL, "Recieved ACK Packet.\t");
                dbg(TRANSPORT_CHANNEL, "AdvertiseWindow size(%hhu)\n", TCPPackage.advertisedWindow);
                if(TCPPackage.advertisedWindow != socket.effectiveWindow){
                    dbg(TRANSPORT_CHANNEL,"Adjusted effectiveWindow(%hhu) to match advertisedWindow(%hhu)...\n", socket.effectiveWindow, TCPPackage.advertisedWindow);
                    socket.effectiveWindow = TCPPackage.advertisedWindow;
                }

            }else if(TCPPackage.flags == 0){

            }
        }
        //CLOSED
        else if (socket.state == CLOSED) {
            // This socket is not open to communication, so do nothing
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: CLOSED\n");
        }

        //push socket back into list
        call socketList.pushfront(socket);
        return error;
   }

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
   command error_t Transport.connect(socket_t fd, socket_addr_t * addr){
       bool found = FALSE;
       socket_store_t socket;
       pack packet;
       error_t error;

       if (call usedSockets.contains(fd)) {
           // If socket fd exists, extract it from the list
           while (!found) {
               socket = call socketList.popfront();
               if (socket.fd == fd) {
                   break;
               }
               else {
                   call socketList.pushback(socket);
               }
           }

           if (socket.state == CLOSED) {
               // This socket is currently idle
               // Set the destination address
               socket.dest = *addr;

               // Send a SYN packet
               makeTCPPack(&TCPPackage, socket.src.port, socket.dest.port, 0, 0, 0, 0, "SYN", TCP_PACKET_MAX_PAYLOAD_SIZE);
               setFlagBit(&TCPPackage, SYN_FLAG_BIT);
               makePack(&sendPackage, socket.src.addr, socket.dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
               memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
               socket.lastWritten = 0;

               dbg(TRANSPORT_CHANNEL,"CLIENT[%hhu][%hhu]: Sending a SYN packet to Server[%hhu][%hhu]...\n",
                    socket.src.addr, socket.src.port, socket.dest.addr, socket.dest.port);
               if (signal Transport.send(&sendPackage) == SUCCESS) {
                   makeOutstanding(sendPackage, RTT_ESTIMATE);
                   socket.state = SYN_SENT;
                   socket.lastSent = 0;
                   //push socket back into list
                   dbg(TRANSPORT_CHANNEL,"SUCCESSFULLY SENT SYN PACKAGE\n");
                   error = SUCCESS;
               }
           }
           else if (socket.state == SYN_SENT) {
               // This socket has already sent a SYN packet
               if (socket.dest.addr == addr->addr && socket.dest.port == addr->port) {
                   // Same destination, resend the SYN packet
                   // Send a SYN packet
                   makeTCPPack(&TCPPackage, socket.src.port, socket.dest.port, 0, 0, 0, 0, "", TCP_PACKET_MAX_PAYLOAD_SIZE);
                   setFlagBit(&TCPPackage, SYN_FLAG_BIT);
                   makePack(&sendPackage, socket.src.addr, socket.dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                   memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                   if (signal Transport.send(&sendPackage) == SUCCESS) {
                       makeOutstanding(sendPackage, RTT_ESTIMATE);
                       error = SUCCESS;
                   }
               }
               else {
                   // If the destination is different this time, what to do?
                   error = FAIL;
               }
           }

           //push socket back into list
           call socketList.pushfront(socket);
       }

       return error;
   }

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
           //looking for socket...
            while(!found){
                    socket = call socketList.popfront();
                    if(socket.fd == fd){
                        dbg(TRANSPORT_CHANNEL,"FOUND socket %hhu in socketList.\n", fd);
                        found = TRUE;
                    }else{
                        //not it
                        call socketList.pushback(socket);
                    }
                }
            //Found it, check for active connection and change states.
            //NOTE: 0 REFERS TO AN OPEN SOCKET, NOT A SOCKET WITH AN ESTABLISHED CONNECTION
           if(call usedSockets.get(fd) != 0){
                dbg(TRANSPORT_CHANNEL,"socket %hhu is in use, force closing...\n", fd);
                //remove indicator of established connection
                call usedSockets.set(fd, 0);
           }
           //changing socket to LISTEN
            socket.state = LISTEN;
            socket.dest.port = 0;
            socket.dest.addr = 0;
            call socketList.pushfront(socket);//pushing data back into list
            dbg(TRANSPORT_CHANNEL, "Changed socket state to LISTEN(%hhu)\n", socket.state);
           dbg(TRANSPORT_CHANNEL,"Starting timer to listen for connections...\n");
           listenFd = fd;
           //will check for connection to accept every 5 sSending packet fromeconds
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

    event void resendTimer.fired() {
        // When this timer fires, resend the earliest outstanding packet
        pack packet, nextPacket;
        uint32_t t0, t1, t2;

        t0 = call resendTimer.getNow();

        if (call outstandingPackets.isEmpty()) {
            // Nothing to retransmit, just reset the timer
            call resendTimer.startOneShotAt(t0, RTT_ESTIMATE);
            return;
        }
        
        packet = call outstandingPackets.popfront();
        t1 = call timeToResend.popfront();

        if (t0 < t1) {
            // There is something to retransmit but now is not the time
            // Reset the timer accordingly
            call resendTimer.startOneShotAt(t0, t1 - t0);
            return;
        }

        // Resend the packet
        signal Transport.send(&packet);
        
        // Push it to the back of the list
        call outstandingPackets.pushback(packet);
        call timeToResend.pushback(call resendTimer.getNow() + RTT_ESTIMATE);

        // Calculate time until the next packet times out
        nextPacket = call outstandingPackets.front();
        t2 = call timeToResend.front();

        call resendTimer.startOneShotAt(t1, t2 - t1);
    }

    void makeOutstanding(pack Package, uint16_t timeoutValue) {
        call outstandingPackets.pushback(Package);
        call timeToResend.pushback(call resendTimer.getNow() + timeoutValue);
    }

    void acknowledgePacket(pack* ackPack) {
        // Try to match the ACK packet with an outstanding packet and remove that outstanding packet from the list
        pack sentPack;
        tcp_pack sentTCP, ackTCP;
        uint32_t t;
        uint16_t i, numOutstanding = call outstandingPackets.size();
        extractTCPPack(ackPack, &ackTCP);
        if (checkFlagBit(&ackTCP, ACK_FLAG_BIT)) {
            for (i = 0; i < numOutstanding; i++) {
                sentPack = call outstandingPackets.popfront();
                t = call timeToResend.popfront();
                if (sentPack.src == ackPack->dest && sentPack.dest == ackPack->src) {
                    extractTCPPack(&sentPack, &sentTCP);
                    if (sentTCP.srcPort == ackTCP.destPort && sentTCP.destPort && ackTCP.srcPort) {
                        if (sentTCP.byteSeq < ackTCP.acknowledgement && sentTCP.byteSeq + TCP_PACKET_MAX_PAYLOAD_SIZE + 1 >= ackTCP.acknowledgement) {
                            // Found a match, remove it from the list (not sure if this is correct) REPLY: I think you're fine.
                            // dbg(TRANSPORT_CHANNEL, "Outstanding packet removed\n");
                            continue;
                        }
                    }
                }
                // The packet doesn't match, return it to the list
                call outstandingPackets.pushback(sentPack);
                call timeToResend.pushback(t);
            }
        }
    }

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }

   void makeTCPPack(tcp_pack *Package, uint8_t srcPort, uint8_t destPort, uint16_t byteSeq, uint16_t acknowledgement, uint8_t flags, uint8_t advertisedWindow, uint8_t *payload, uint8_t length) {
      Package->srcPort = srcPort;
      Package->destPort = destPort;
      Package->byteSeq = byteSeq;
      Package->acknowledgement = acknowledgement;
      Package->flags = flags;
      Package->advertisedWindow = advertisedWindow;
      memcpy(Package->payload, payload, length);
   }

   void extractTCPPack(pack *Package, tcp_pack *TCPPack) {
       memcpy(TCPPack, &Package->payload, PACKET_MAX_PAYLOAD_SIZE);
   }

    socket_store_t* getSocketPtr(socket_t fd) {
        // Return a pointer to the specified socket if it exists, return NULL otherwise
        uint16_t i, numSockets;
        socket_store_t* socket;

        numSockets = call socketList.size();
        for (i = 0; i < numSockets; i++) {
            socket = call socketList.getPtr(i);
            if (socket->fd == fd) {
                return socket;
            }
        }
    }
}
