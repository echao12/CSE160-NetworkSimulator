
#include "../../includes/socket.h"

module TransportP{
    // provides shows the interface we are implementing. See lib/interface/Transport.nc
    // to see what funcitons we need to implement.
   provides interface Transport;
   uses interface List<socket_store_t> as socketList;
   uses interface Random;
   //track available sockets. value(0):open socket, value(1) established connection
   uses interface Hashmap<socket_t> as usedSockets;

   // track outstanding packets
   uses interface List<pack> as outstandingPackets;
   uses interface List<uint32_t> as timeToResend;
   uses interface Timer<TMilli> as resendTimer;
   uses interface List<uint16_t> as resendAttempts;
}


implementation{
   pack sendPackage;
   tcp_pack TCPPackage;
   socket_t curSocketNumber;
   uint8_t portNum = 1;

   void processPacket(socket_store_t* socket, tcp_pack* packet);
   uint16_t sendFromBuffer(socket_store_t* socket, uint8_t advertisedWindow);

   void makeOutstanding(pack Package, uint16_t timeoutValue);
   void acknowledgePacket(socket_store_t* socket, pack *Package);

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   void makeTCPPack(tcp_pack *Package, uint8_t srcPort, uint8_t destPort, uint8_t byteSeq, uint16_t acknowledgement, uint8_t flags, uint8_t advertisedWindow, uint8_t *payload, uint8_t length);
   void extractTCPPack(pack *Package, tcp_pack* TCPPack);
   void removeSocketFromList(socket_t fd);

   socket_store_t* getSocketPtr(socket_t fd);
   uint8_t increaseByteSeq(uint8_t byteSeq, uint8_t x);
   uint8_t decreaseByteSeq(uint8_t byteSeq, uint8_t x);
   void resetBuffer(uint8_t* buff, uint16_t bufflen);
   uint16_t getPayloadLength(uint8_t* buff);

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
        if (fd != NULL_SOCKET && addr != NULL) {
            // Initialize socket
            socketConfig.fd = fd;
            socketConfig.src.addr = addr->addr;
            socketConfig.src.port = addr->port;
            socketConfig.dest.addr = 0;
            socketConfig.dest.port = 0;
            socketConfig.state = CLOSED;
            socketConfig.bufferState = TYPICAL;
            resetBuffer(socketConfig.sendBuff, SOCKET_BUFFER_SIZE);
            resetBuffer(socketConfig.rcvdBuff, SOCKET_BUFFER_SIZE);
            socketConfig.lastWritten = socketConfig.lastAck = socketConfig.lastSent = 0;
            socketConfig.lastRead = socketConfig.lastRcvd = socketConfig.nextExpected = 0;
            socketConfig.RTT = RTT_ESTIMATE;

            call socketList.pushback(socketConfig);//adding it to this node's socketlist
            dbg(TRANSPORT_CHANNEL, "SUCESSFULLY BOUNDED!\n");
            error = SUCCESS;
            call resendTimer.startOneShotAt(call resendTimer.getNow(), RTT_ESTIMATE);

            signal Transport.addSocket(fd);
        }
        else {
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
    command socket_t Transport.accept(socket_t fd) {
        socket_store_t* currentSocket;
        socket_t newSocketFD;

        if (call socketList.isFull()) {
            // Can't add any more socket
            return NULL_SOCKET;
        }
        else {
            // Create a copy of the current socket and return that socket's fd
            currentSocket = getSocketPtr(fd);
            newSocketFD = call Transport.socket();
            call Transport.bind(newSocketFD, &currentSocket->src);
            return newSocketFD;
        }
    }

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
        uint16_t i, bytePos, bytesWritten;
        char letter;
        //dbg(APPLICATION_CHANNEL, "Writing to sendBuffer...\n");
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

        // Write buffer byte by byte
        bytesWritten = 0;
        bytePos = socket->lastWritten;
        for (i = 0; i < bufflen; i++) {
            bytePos = increaseByteSeq(bytePos, 1);
            if (socket->sendBuff[bytePos] == 0) {
                // This position of the send buffer is empty, fill it
                dbg(P4_DBG_CHANNEL, "Writting [%hhu]->[%c] to buffer[%hhu]\n", buff[i],buff[i], i);
                socket->sendBuff[bytePos] = buff[i];
                bytesWritten++;
                socket->lastWritten = bytePos;
                if (socket->lastAck < socket->lastWritten) {
                    socket->bufferState = TYPICAL;
                }
                else if (socket->lastWritten < socket->lastAck) {
                    socket->bufferState = WRAP;
                }
                else {
                    socket->bufferState = FULL;
                    break;
                }
            }
            else {
                // Send buffer is already full
                break;
            }
        }

        return bytesWritten;
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
        socket_store_t* socket = NULL;
        socket_t socketFD;
        uint16_t i, numSockets, numPacketsSent;
        error_t error;
        uint8_t advertisedWindow, nextByteSeq;

        dbg(TRANSPORT_CHANNEL, "Transport Module: \nNODE(%hhu) RECIEVED TCP Packet seq#(%hhu)\n", TOS_NODE_ID, package->seq);
        extractTCPPack(package, &TCPPackage);
        logTCPPack(&TCPPackage);
        

        // Check if this packet is intended for one of the sockets
        numSockets = call socketList.size();
        for (i = 0; i < numSockets; i++) {
            socket = call socketList.getPtr(i);
            if (socket->src.addr == package->dest && socket->src.port == TCPPackage.destPort) {
                dbg(TRANSPORT_CHANNEL, "FOUND SOCKET\n");
                break;
            }
            else {
                socket = NULL;
            }
        }

        if (socket == NULL) {
            dbg(TRANSPORT_CHANNEL, "FAILED: Could not find corresponding socket for the packet.\n*DROPPED TCP PACKET!*\n");
            return FAIL;
        }

        // dbg(TRANSPORT_CHANNEL, "Checking socket state...(STATE:%hhu)\n", socket->state);
        //LISTEN
        if (socket->state == LISTEN) {
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: LISTENING...\n");
            //check for a SYN msg
            if (checkFlagBit(&TCPPackage, SYN_FLAG_BIT)) {
                dbg(TRANSPORT_CHANNEL, "RECEIVED SYN PACKET(sender seq#: %hhu)\nREPLYING with SYN/ACK TCP Packet\n", package->seq);
                
                // Try to create a new socket for the connection
                socketFD = call Transport.accept(socket->fd);
                
                if (socketFD == NULL_SOCKET) {
                    // Failed to create a new socket
                    return FAIL;
                }
                
                // Switch over to the new socket
                socket = getSocketPtr(socketFD);

                // Not sure about this one, but the new socket shouldn't have the same port as the old one
                socket->src.port += portNum;
                portNum++;

                // Record packet source as this port's destination
                socket->dest.addr = package->src;
                socket->dest.port = TCPPackage.srcPort;

                // Initialize sliding window parameters
                // Note: There's no need to initialize byteSeq for the server (unlike the example given in the book) because
                // the server isn't going to send any data to the client in this project.
                socket->bufferState = TYPICAL;
                socket->lastRead = TCPPackage.byteSeq;
                socket->nextExpected = increaseByteSeq(TCPPackage.byteSeq, 1);
                socket->lastRcvd = TCPPackage.byteSeq;
                advertisedWindow = SOCKET_BUFFER_SIZE;  // Buffer is empty, so advertise max window size

                // Reply with a SYN+ACK packet
                makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, 0, socket->nextExpected, 0, advertisedWindow, "SYN_REPLY", TCP_PACKET_MAX_PAYLOAD_SIZE);
                setFlagBit(&TCPPackage, SYN_FLAG_BIT);
                setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                
                if (signal Transport.send(&sendPackage) == SUCCESS) {
                    makeOutstanding(sendPackage, RTT_ESTIMATE);
                    socket->state = SYN_RCVD;
                    error = SUCCESS;
                }
            }
        }
        //STATE: SYN_SENT, check to see if we got syn/ack packet.
        else if (socket->state == SYN_SENT) {
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: SYN_SENT\n");
            // Check for SYN+ACK packet
            if (checkFlagBit(&TCPPackage, SYN_FLAG_BIT) && checkFlagBit(&TCPPackage, ACK_FLAG_BIT)) {
                dbg(TRANSPORT_CHANNEL, "RECEIVED SYN+ACK PACKET\nREPLYING with ACK TCP Packet\n");

                socket->dest.port = TCPPackage.srcPort;  // Change dest.port to match the receiver's new socket
                
                // Update sliding window parameters
                socket->lastAck = decreaseByteSeq(TCPPackage.acknowledgement, 1);
                nextByteSeq = increaseByteSeq(socket->lastSent, 1);
                advertisedWindow = SOCKET_BUFFER_SIZE;
                
                // Reply with an ACK packet
                makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, nextByteSeq, 1, 0, advertisedWindow, "ACK", TCP_PACKET_MAX_PAYLOAD_SIZE);
                setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);

                if (signal Transport.send(&sendPackage) == SUCCESS) {
                    acknowledgePacket(socket, package);
                    makeOutstanding(sendPackage, RTT_ESTIMATE);
                    
                    socket->lastWritten = nextByteSeq;
                    socket->lastSent = nextByteSeq;
                    socket->state = ESTABLISHED;

                    // Adjust usedSocket value
                    call usedSockets.set(socket->fd, 1);
                    dbg(P4_DBG_CHANNEL, "\nSOCKET(%hhu):[%hhu][%hhu]->[%hhu][%hhu] STATE IS NOW ESTABLISHED\n",
                    socket->fd, socket->src.addr, socket->src.port, socket->dest.addr, socket->dest.port);
                    
                    error = SUCCESS;
                }
            }
        }
        //SYN_RCVD
        else if (socket->state == SYN_RCVD) {
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: SYN_RCVD\n");
            // Check for any ACK packet with proper seq#
            if (checkFlagBit(&TCPPackage, ACK_FLAG_BIT)) {
                dbg(TRANSPORT_CHANNEL, "RECEIVED ACK PACKET\n");
                
                // Update sliding window parameters
                socket->nextExpected = increaseByteSeq(TCPPackage.byteSeq, 1);
                socket->lastRcvd = TCPPackage.byteSeq;
                advertisedWindow = SOCKET_BUFFER_SIZE;
                
                socket->state = ESTABLISHED;  // Change state to ESTABLISHED no matter what
                acknowledgePacket(socket, package);
                
                // Adjust usedSocket Map value
                call usedSockets.set(socket->fd, 1); //1 is established, 0 is not
                dbg(P4_DBG_CHANNEL, "\nSOCKET(%hhu):[%hhu][%hhu]->[%hhu][%hhu] STATE IS NOW ESTABLISHED\n",
                    socket->fd, socket->src.addr, socket->src.port, socket->dest.addr, socket->dest.port);
                
                // Send an ACK packet to the client, it doesn't matter if this ACK packet reaches the client or not
                makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, 1, socket->nextExpected, 0, advertisedWindow, "ACK", TCP_PACKET_MAX_PAYLOAD_SIZE);
                setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                resetBuffer(TCPPackage.payload, TCP_PACKET_MAX_PAYLOAD_SIZE);
                makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);

                if (signal Transport.send(&sendPackage) == SUCCESS) {
                    socket->lastRead = TCPPackage.byteSeq;
                    error = SUCCESS;
                }
            }
        }
        //ESTABLISHED
        else if (socket->state == ESTABLISHED) {
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: ESTABLISHED\n");
            if (checkFlagBit(&TCPPackage, SYN_FLAG_BIT)) {
                // Ignore any SYN packet
            }
            else if (checkFlagBit(&TCPPackage, ACK_FLAG_BIT)) {
                dbg(TRANSPORT_CHANNEL, "Received ACK packet, advertisedWindow = %hhu\n", TCPPackage.advertisedWindow);
                acknowledgePacket(socket, package);
                i = getPayloadLength(TCPPackage.payload);
                
                // Process the packet first (mostly used by the receiver side)
                processPacket(socket, &TCPPackage);

                // Send some amount of packets depending on how much data is in the send buffer and also the advertisedWindow
                numPacketsSent = sendFromBuffer(socket, TCPPackage.advertisedWindow);

                if (numPacketsSent == 0 && i > 0) {
                    // Send at least an ACK packet
                    advertisedWindow = SOCKET_BUFFER_SIZE - (socket->nextExpected - 1 - socket->lastRead);
                    makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, 0, socket->nextExpected, 0, advertisedWindow, "null", TCP_PACKET_MAX_PAYLOAD_SIZE);
                    setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                    resetBuffer(TCPPackage.payload, TCP_PACKET_MAX_PAYLOAD_SIZE);
                    makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                    memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);

                    signal Transport.send(&sendPackage);
                }
                error = SUCCESS;

            }else if(checkFlagBit(&TCPPackage, FIN_FLAG_BIT)){
                //signal server that client wants to close connection
                dbg(TRANSPORT_CHANNEL, "Recieved FIN Packet.\nLink: [%hhu][%hhu]<----->[%hhu][%hhu]\nSTARTING DISCONNECTION...\n",
                socket->src.addr, socket->src.port, socket->dest.addr, socket->dest.port);
                acknowledgePacket(socket, package);//packet received

                //send CLOSE_WAIT packet to ack the FIN
                makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, socket->lastSent+1, socket->nextExpected, 0, 0, "FIN ACK", TCP_PACKET_MAX_PAYLOAD_SIZE);
                TCPPackage.flags = 0;//reset flags
                //setFlagBit(&TCPPackage, FIN_FLAG_BIT);
                setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                if(signal Transport.send(&sendPackage) == SUCCESS){
                    dbg(TRANSPORT_CHANNEL, "Server:[%hhu][%hhu]Sending FIN_ACK to client[%hhu][%hhu]...\n",
                    socket->src.addr, socket->src.port, socket->dest.addr, socket->dest.port);
                    socket->state = CLOSE_WAIT;
                    dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: CLOSE_WAIT\n");
                    //makeOutstanding(sendPackage, RTT_ESTIMATE); //for FIN_ACKs, we dont needa recieve an ack back. dont add to outstanding
                    socket->lastSent++;
                    error = SUCCESS;
                }

                //send FIN back to the client
                makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, socket->lastSent+1, socket->nextExpected, 0, 0, "FIN_LAST_ACK", TCP_PACKET_MAX_PAYLOAD_SIZE);
                TCPPackage.flags = 0;//reset flags
                setFlagBit(&TCPPackage, FIN_FLAG_BIT);
                makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                if(signal Transport.send(&sendPackage) == SUCCESS){
                    dbg(TRANSPORT_CHANNEL, "Server:[%hhu][%hhu]Sending LAST_ACK to client[%hhu][%hhu]...\n",
                    socket->src.addr, socket->src.port, socket->dest.addr, socket->dest.port);
                    socket->state = LAST_ACK;
                    dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: LAST_ACK\n");
                    makeOutstanding(sendPackage, RTT_ESTIMATE);
                    socket->lastSent++;
                    error = SUCCESS;
                }


            }else if(TCPPackage.flags == 0){
                //not sure yet
            }
        }else if(socket->state == FIN_WAIT_1){
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: FIN_WAIT_1\n");
            //update socket data
            socket->lastRcvd = TCPPackage.byteSeq;
            socket->nextExpected = TCPPackage.byteSeq + 1;
            //checking for FIN/ACK packet
            if(checkFlagBit(&TCPPackage, ACK_FLAG_BIT)){
                dbg(TRANSPORT_CHANNEL,"RECIEVED FIN/ACK!\n");
                //waiting for LAST_ACK from server.
                socket->state = FIN_WAIT_2;
                //acknowledgePacket(package);
            }
            //send 
        }else if(socket->state == FIN_WAIT_2){
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: FIN_WAIT_2\n");
            //update socket data
            socket->lastRcvd = TCPPackage.byteSeq;
            socket->nextExpected = TCPPackage.byteSeq + 1;
            if(checkFlagBit(&TCPPackage, FIN_FLAG_BIT)){
                dbg(TRANSPORT_CHANNEL,"RECIEVED FIN!\n");
                acknowledgePacket(socket, package);
                //send ACK back
                makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, socket->lastSent+1, socket->nextExpected, 0, 0, "FIN_RP_L_ACK", TCP_PACKET_MAX_PAYLOAD_SIZE);
                TCPPackage.flags = 0;//reset flags
                setFlagBit(&TCPPackage, ACK_FLAG_BIT);
                makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                if(signal Transport.send(&sendPackage) == SUCCESS){
                    socket->state = TIME_WAIT;
                    dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: TIME_WAIT\n");
                    makeOutstanding(sendPackage, RTT_ESTIMATE);//will retransmit, but we wait for a timeout anyways
                    socket->lastSent++;
                    error = SUCCESS;
                }
                socket->state = CLOSED;
                dbg(TRANSPORT_CHANNEL,"\n**SOCKET[%hhu][%hhu] IS CLOSED**\n",socket->src.addr, socket->src.port);
                //remove from usedSockets and socketList.
                call usedSockets.remove(socket->fd);
                removeSocketFromList(socket->fd);
                dbg(TRANSPORT_CHANNEL, "Mote(%hhu): Socket is removed from socketList and usedSockets...\n", TOS_NODE_ID);

            }

        }else if(socket->state == LAST_ACK){
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: LAST_ACK\n");
            //check for an ack packet
            socket->lastRcvd = TCPPackage.byteSeq;
            socket->nextExpected = TCPPackage.byteSeq + 1;
            if(checkFlagBit(&TCPPackage, ACK_FLAG_BIT)){
                dbg(TRANSPORT_CHANNEL, "RECIEVED AN ACK!\nClosing the connection...");
                acknowledgePacket(socket, package);
                //close the connection
                socket->state = CLOSED;
                dbg(TRANSPORT_CHANNEL,"\n**SOCKET[%hhu][%hhu] IS CLOSED**\n",socket->src.addr, socket->src.port);
                dbg(TRANSPORT_CHANNEL, "\nLink: [%hhu][%hhu]<----->[%hhu][%hhu] Terminated...\n",
                socket->src.addr, socket->src.port, socket->dest.addr, socket->dest.port);
                call usedSockets.remove(socket->fd);
                removeSocketFromList(socket->fd);
                dbg(TRANSPORT_CHANNEL, "Mote(%hhu): Socket is removed from socketList and usedSockets...\n", TOS_NODE_ID);
                dbg(TRANSPORT_CHANNEL, "\n\nDone Cleaning up Link...\n\n");
            }
        }
        //CLOSED
        else if (socket->state == CLOSED) {
            // This socket is not open to communication, so do nothing
            dbg(TRANSPORT_CHANNEL, "CURRENT SOCKET STATE: CLOSED\n");
            error = FAIL;
        }

        return error;
    }

    void processPacket(socket_store_t* socket, tcp_pack* packet) {
        // Process a TCP packet
        uint16_t i, num, bytePos;

        // Process the payload byte by byte
        for (i = 0; i < TCP_PACKET_MAX_PAYLOAD_SIZE; i+=2) {
            memcpy(&num, &packet->payload[i], 2);
            if (num == 0) {
                // End of payload
                break;
            }

            // Determine the position of this byte in the receive buffer
            bytePos = increaseByteSeq(packet->byteSeq, i);

            if (socket->rcvdBuff[bytePos] == 0) {
                // Only fill this part of the buffer if it is empty
                memcpy(&socket->rcvdBuff[bytePos], &num, 2);
                dbg(TRANSPORT_CHANNEL, "rcvdBuff[%hhu] = %hhu\n", bytePos, socket->rcvdBuff[bytePos]);

                // Update sliding window parameters (receiver side)
                if (socket->bufferState == TYPICAL) {
                    if (bytePos > socket->lastRcvd || bytePos < socket->lastRead) {
                        socket->lastRcvd = bytePos;
                        if (socket->lastRcvd < socket->lastRead) {
                            socket->bufferState = WRAP;
                        }
                    }
                }
                else {
                    if (socket->lastRcvd < bytePos && bytePos <= socket->lastRead) {
                        socket->lastRcvd = bytePos;
                        if (socket->lastRcvd == socket->lastRead) {
                            socket->bufferState = FULL;
                        }
                    }
                }

                if (socket->bufferState != FULL) {
                    memcpy(&num, &socket->rcvdBuff[socket->nextExpected], 2);
                    while (num != 0) {
                        socket->nextExpected = increaseByteSeq(socket->nextExpected, 2);
                        memcpy(&num, &socket->rcvdBuff[socket->nextExpected], 2);
                    }
                }
            }
        }
    }

    uint16_t sendFromBuffer(socket_store_t* socket, uint8_t advertisedWindow) {
        // Empty send buffer by sending as many packets as possible (keep in mind the advertisedWindow size)
        uint16_t i, j, num, bytePos, packetsSent = 0;
        bool isEmpty;

        // Calculate effective window size
        if (socket->lastSent >= socket->lastAck) {
            if (advertisedWindow > socket->lastSent - socket->lastAck) {
                socket->effectiveWindow = advertisedWindow - (socket->lastSent - socket->lastAck);
            }
            else {
                socket->effectiveWindow = 0;
            }
        }
        else {
            if (advertisedWindow > SOCKET_BUFFER_SIZE + socket->lastSent - socket->lastAck) {
                socket->effectiveWindow = advertisedWindow - (SOCKET_BUFFER_SIZE + socket->lastSent - socket->lastAck);
            }
            else {
                socket->effectiveWindow = 0;
            }
        }
        dbg(TRANSPORT_CHANNEL, "AdvertisedWindow %hhu  Effective Window %hhu\n", advertisedWindow, socket->effectiveWindow);

        // Calculate this socket's advertisedWindow
        advertisedWindow = SOCKET_BUFFER_SIZE - (socket->nextExpected - 1 - socket->lastRead);

        bytePos = increaseByteSeq(socket->lastSent, 1);
        for (i = 0; i < socket->effectiveWindow; i += TCP_PACKET_MAX_PAYLOAD_SIZE) {
            // Create a packet
            makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, bytePos, socket->nextExpected, 0, advertisedWindow, "TBD", TCP_PACKET_MAX_PAYLOAD_SIZE);
            setFlagBit(&TCPPackage, ACK_FLAG_BIT);

            // Fill the payload with data from send buffer
            isEmpty = TRUE;
            for (j = 0; j < TCP_PACKET_MAX_PAYLOAD_SIZE; j += 2) {
                memcpy(&num, &socket->sendBuff[bytePos], 2);
                bytePos = increaseByteSeq(bytePos, 2);
                if (i + j + 2 > socket->effectiveWindow) {
                    break;
                }
                else if (num == 0) {
                    break;
                }
                else if (socket->bufferState == FULL && bytePos == increaseByteSeq(socket->lastAck, 1)) {
                    break;
                }
                else {
                    dbg(TRANSPORT_CHANNEL, "sendBuff[%hhu] = %hhu\n", decreaseByteSeq(bytePos, 2), num);
                    memcpy(&TCPPackage.payload[j], &num, 2);
                    socket->lastSent = decreaseByteSeq(bytePos, 1);
                    isEmpty = FALSE;
                }
            }
            for (; j < TCP_PACKET_MAX_PAYLOAD_SIZE; j++) {
                TCPPackage.payload[j] = 0;
            }

            if (isEmpty) {
                break;
            }
            else {
                dbg(TRANSPORT_CHANNEL, "Sending packet\n");
            }

            makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
            memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);

            signal Transport.send(&sendPackage);
            makeOutstanding(sendPackage, RTT_ESTIMATE);
            packetsSent++;
        }

        return packetsSent;
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
    command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen){
        socket_store_t* socket;
        uint16_t i, num, bytePos, bytesRead;
        
        // Get the specified socket
        socket = getSocketPtr(fd);

        if (socket == NULL) {
            // The specified socket doesn't exist
            // dbg(TRANSPORT_CHANNEL, "Error in Transport.read: Socket %hhu doesn't exist\n", fd);
            return 0;
        }
        else if (socket->state != ESTABLISHED) {
            // The specified socket doesn't have a connection yet
            // dbg(TRANSPORT_CHANNEL, "Error in Transport.read: Socket %hhu is not in ESTABLISHED state\n", fd);
            return 0;
        }

        // Read buffer byte by byte
        bytesRead = 0;
        bytePos = increaseByteSeq(socket->lastRead, 1);
        for (i = 0; i < bufflen; i+=2) {
            memcpy(&num, &socket->rcvdBuff[bytePos], 2);
            if (num != 0) {
                // There is something to read
                memcpy(&buff[i], &num, 2);  // copy the data
                socket->rcvdBuff[bytePos] = 0;
                socket->rcvdBuff[bytePos+1] = 0;    
                socket->lastRead = bytePos+1;
                if (socket->lastRead < socket->lastRcvd) {
                    socket->bufferState = TYPICAL;
                }
                else {
                    socket->bufferState = WRAP;
                }
                bytesRead += 2;
            }
            else {
                // No more data to read
                socket->nextExpected = bytePos;
                break;
            }
            bytePos = increaseByteSeq(bytePos, 2);
        }

        return bytesRead;
    }

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
        socket_store_t* socket;
        uint8_t initialByteSeq;

        // Get the specified socket
        socket = getSocketPtr(fd);

        if (socket == NULL) {
            // The specified socket does not exist
            return FAIL;
        }
        else if (socket->state != CLOSED) {
            // The specified socket is not currently idle
            return FAIL;
        }

        // Set destination address (this can still change during the three-way handshake)
        socket->dest = *addr;

        // Initialize sliding window parameters
        socket->bufferState = TYPICAL;
        initialByteSeq = 0;  // Set as 0 for now, but randomize it later after everything's working (note: always pick an even number)
        socket->lastAck = initialByteSeq;
        socket->lastSent = initialByteSeq;
        socket->lastWritten = initialByteSeq;

        // Send a SYN packet
        makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, initialByteSeq, 0, 0, 0, "SYN", TCP_PACKET_MAX_PAYLOAD_SIZE);
        setFlagBit(&TCPPackage, SYN_FLAG_BIT);
        makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
        memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);

        dbg(TRANSPORT_CHANNEL,"CLIENT[%hhu][%hhu]: Sending a SYN packet to Server[%hhu][%hhu]...\n",
            socket->src.addr, socket->src.port, socket->dest.addr, socket->dest.port);
        
        if (signal Transport.send(&sendPackage) == SUCCESS) {
            makeOutstanding(sendPackage, RTT_ESTIMATE);
            socket->state = SYN_SENT;
             dbg(TRANSPORT_CHANNEL,"SUCCESSFULLY SENT SYN PACKAGE\n");
            return SUCCESS;
        }
        else {
            // Failed to send a SYN package
            dbg(TRANSPORT_CHANNEL, "ERROR: Failed to send SYN packet\n");
            return FAIL;
        }
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
   command error_t Transport.close(socket_t fd){
       error_t error;
       socket_store_t *socket;
       socket = getSocketPtr(fd);
       //ensure that fs isn't null
       if(fd != NULL_SOCKET){
           //send the FIN packet
            makeTCPPack(&TCPPackage, socket->src.port, socket->dest.port, socket->lastSent+1, socket->nextExpected, 0, 0, "FIN", TCP_PACKET_MAX_PAYLOAD_SIZE);
            TCPPackage.flags = 0;//reset flags
            setFlagBit(&TCPPackage, FIN_FLAG_BIT);
            makePack(&sendPackage, socket->src.addr, socket->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
            memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
            if(signal Transport.send(&sendPackage) == SUCCESS){
                socket->state = FIN_WAIT_1;
                makeOutstanding(sendPackage, RTT_ESTIMATE);
                socket->lastSent++;
            }
            error = SUCCESS;
       }else{
           error = FAIL;
       }
       return error;
   }

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
        socket_store_t* socket;

        dbg(TRANSPORT_CHANNEL, "Attempting to listen to socket %hhu\n", fd);

        // Get the specified socket
        socket = getSocketPtr(fd);

        if (socket == NULL) {
            // The specified socket does not exist
            return FAIL;
        }
        else if (socket->state != CLOSED) {
            // The specified socket is not currently idle
            return FAIL;
        }

        // Change socket state to LISTEN
        socket->state = LISTEN;
        socket->dest.port = 0;
        socket->dest.addr = 0;
        
        dbg(P4_DBG_CHANNEL, "Listening at Addr[%hhu]:Port[%hhu] %hhu\n", socket->src.addr, socket->src.port);
        return SUCCESS;
    }

    //to find fd of socket with address info
    command socket_t Transport.findSocket(socket_addr_t *srcAddr, socket_addr_t *destAddr){
        socket_t socketNum;
        bool found = FALSE;
        uint8_t count = 0;
        socket_store_t socket;
        dbg(TRANSPORT_CHANNEL,"Looking for Socket!\n");
        if(srcAddr != NULL && destAddr != NULL){
            while(!found && count < MAX_NUM_OF_SOCKETS){
                socket = call socketList.popfront();
                if(socket.src.addr == srcAddr->addr && socket.src.port == srcAddr->port){
                    if(socket.dest.addr == destAddr->addr){
                        //matches
                        socketNum = socket.fd;
                        found = TRUE;
                    }else{
                        //no match
                        socketNum = NULL_SOCKET;
                    }
                }
                //push back data
                call socketList.pushback(socket);
                count++;
            }
        }else{
            socketNum = NULL_SOCKET;
        }
        return socketNum;
    }

    event void resendTimer.fired() {
        // When this timer fires, resend the earliest outstanding packet
        pack packet;
        uint32_t t0, t1, t2;
        uint16_t attempt;

        t0 = call resendTimer.getNow();

        if (call outstandingPackets.isEmpty()) {
            // Nothing to retransmit, just reset the timer
            call resendTimer.startOneShotAt(t0, RTT_ESTIMATE);
            return;
        }

        t1 = call timeToResend.front();

        if (t0 < t1) {
            // There is something to retransmit but now is not the time
            // Reset the timer accordingly
            call resendTimer.startOneShotAt(t0, t1 - t0);
            return;
        }

        packet = call outstandingPackets.popfront();
        t1 = call timeToResend.popfront();
        attempt = call resendAttempts.popfront();

        // Resend the packet
        signal Transport.send(&packet);
        attempt += 1;
        
        if (attempt < MAX_RESEND_ATTEMPTS) {
            // Push it to the back of the list
            call outstandingPackets.pushback(packet);
            call timeToResend.pushback(t1 + RTT_ESTIMATE);
            call resendAttempts.pushback(attempt);
        }
        else {
            dbg(TRANSPORT_CHANNEL, "Maximum retransmission attempts reached, packet is dropped\n");
        }
        
        // Calculate time until the next packet times out
        if (call outstandingPackets.isEmpty()) {
            t2 = t0 + RTT_ESTIMATE;
        }
        else {
            t2 = call timeToResend.front();
        }
        call resendTimer.startOneShotAt(t1, t2 - t1);
    }

    void makeOutstanding(pack Package, uint16_t timeoutValue) {
        call outstandingPackets.pushback(Package);
        call timeToResend.pushback(call resendTimer.getNow() + timeoutValue);
        call resendAttempts.pushback(0);
    }

    void acknowledgePacket(socket_store_t* socket, pack* ackPack) {
        // Try to match the ACK packet with an outstanding packet and remove that outstanding packet from the list
        pack sentPack;
        tcp_pack sentTCP, ackTCP;
        uint32_t t;
        uint16_t i, attempt, bytePos, numOutstanding = call outstandingPackets.size();
        extractTCPPack(ackPack, &ackTCP);
        if (checkFlagBit(&ackTCP, ACK_FLAG_BIT)) {
            for (i = 0; i < numOutstanding; i++) {
                sentPack = call outstandingPackets.popfront();
                t = call timeToResend.popfront();
                attempt = call resendAttempts.popfront();

                if (sentPack.src == ackPack->dest && sentPack.dest == ackPack->src) {
                    extractTCPPack(&sentPack, &sentTCP);
                    if (sentTCP.srcPort == ackTCP.destPort && sentTCP.destPort && ackTCP.srcPort) {
                        bytePos = increaseByteSeq(socket->lastAck, 1);
                        if (socket->sendBuff[bytePos] == 0) {
                            // This position of the buffer is already freed.
                            // This might happen if the ACK packet arrives too late.
                            continue;
                        }
                        while (bytePos != ackTCP.acknowledgement) {
                            // Free the buffer at this position
                            socket->sendBuff[bytePos] = 0;
                            socket->lastAck = bytePos;
                            if (socket->lastAck < socket->lastWritten) {
                                socket->bufferState = TYPICAL;
                            }
                            else if (socket->lastWritten < socket->lastAck) {
                                socket->bufferState = WRAP;
                            }
                            bytePos = increaseByteSeq(bytePos, 1);
                        }
                        break;
                    }
                }

                // The packet doesn't match, return it to the list
                call outstandingPackets.pushback(sentPack);
                call timeToResend.pushback(t);
                call resendAttempts.pushback(attempt);
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

   void makeTCPPack(tcp_pack *Package, uint8_t srcPort, uint8_t destPort, uint8_t byteSeq, uint16_t acknowledgement, uint8_t flags, uint8_t advertisedWindow, uint8_t *payload, uint8_t length) {
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

    void removeSocketFromList(socket_t fd){
        bool found = FALSE;
        uint8_t count = 0;
        socket_store_t socket;
        dbg(TRANSPORT_CHANNEL,"Looking for Socket(%hhu) to Remove from SocketList!\n", fd);
        if(fd != NULL_SOCKET){
            while(!found && count < MAX_NUM_OF_SOCKETS){
                socket = call socketList.popfront();
                if(socket.fd == fd){
                    //matches
                    found = TRUE;
                    dbg(TRANSPORT_CHANNEL,"Socket(%hhu) removed!\n", socket.fd);
                }
                //push back data
                call socketList.pushback(socket);
                count++;
            }
            if(!found){
                dbg(TRANSPORT_CHANNEL,"SOCKET NOT FOUND: No Sockets removed!\n");
            }
        }
        //if found, socket is removed
    }

    uint8_t increaseByteSeq(uint8_t byteSeq, uint8_t x) {
        // Increase byteSeq by x, wrap around if necessary
        return (byteSeq + x) % SOCKET_BUFFER_SIZE;
    }

    uint8_t decreaseByteSeq(uint8_t byteSeq, uint8_t x) {
        // Decrease byteSeq by x, wrap around if necessary
        if (byteSeq < x) {
            return (byteSeq + SOCKET_BUFFER_SIZE - x) % SOCKET_BUFFER_SIZE;
        }
        else {
            return byteSeq - x;
        }
    }

    void resetBuffer(uint8_t* buff, uint16_t bufflen) {
        // Reset bufflen amount of bytes from the start of the buffer
        uint16_t i;
        for (i = 0; i < bufflen; i++) {
            buff[i] = 0;
        }
    }

    uint16_t getPayloadLength(uint8_t* buff) {
        uint16_t i, num, len = 0;
        for (i = 0; i < TCP_PACKET_MAX_PAYLOAD_SIZE; i += 2) {
            memcpy(&num, &buff[i], 2);
            if (num != 0) {
                len++;
            }
            else {
                break;
            }
        }
        return len;
    }
}
