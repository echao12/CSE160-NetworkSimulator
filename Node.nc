/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include <string.h>
#include<stdio.h> 
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/route.h"
#include "includes/socket.h"


module Node{
   uses interface Boot;

   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;
   
   uses interface Hashmap<uint16_t> as neighborMap;
   uses interface Hashmap<uint16_t> as activeNeighbors;
   //uses interface Hashmap<char*> as userMap;

   uses interface List<pack> as Cache;

   uses interface List<pack> as packetsQueue;

   uses interface RoutingTable as routingTable;

   uses interface Timer<TMilli> as packetsTimer;
   uses interface Timer<TMilli> as neighborTimer;
   uses interface Timer<TMilli> as routingTimer;
   uses interface Random as Random;

   //use the provided transport interface
   uses interface Transport as Transport; // handles sockets
   uses interface Timer<TMilli> as TCPWriteTimer;
   uses interface Timer<TMilli> as TCPReadTimer;
   uses interface List<socket_t> as socketList;

}

implementation{
   pack sendPackage;
   tcp_pack TCPPackage;
   uint16_t currentSequence = 0;

   // TCP-related variables
   socket_t default_socket = NULL_SOCKET;
   uint16_t bytesToTransfer = 0, bytesWrittenSoFar = 0;
   uint16_t msgPosition[MAX_NUM_OF_SOCKETS];
   char username[SOCKET_BUFFER_SIZE], messageBuff[SOCKET_BUFFER_SIZE], fullMessageBuffer[MAX_NUM_OF_SOCKETS][SOCKET_BUFFER_SIZE];
   char connectedUsers[MAX_NUM_OF_SOCKETS][SOCKET_BUFFER_SIZE];
   bool found_r = FALSE, found_n = FALSE;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   void makeTCPPack(tcp_pack *Package, uint8_t srcPort, uint8_t destPort, uint8_t byteSeq, uint16_t acknowledgement, uint8_t flags, uint8_t advertisedWindow, uint8_t *payload, uint8_t length);
   bool checkCache(pack *Package);
   void incrementSequence();
   void updateNeighbors(uint16_t src);
   void messageHandler(socket_t fd);
   void writeToSocket(socket_t fd);

   //TinyOS Boot sequence completed, each mote calls this function.
   event void Boot.booted(){

      uint8_t i = 0;
      call AMControl.start();//start radio

      dbg(GENERAL_CHANNEL, "(%hhu)Booted\n", TOS_NODE_ID);

      //memset(&fullMessageBuffer,'\0', SOCKET_BUFFER_SIZE);
      memset(&messageBuff,'\0', SOCKET_BUFFER_SIZE);
      memset(&username,'\0', SOCKET_BUFFER_SIZE);
      for(i = 0; i < MAX_NUM_OF_SOCKETS; i++){
         fullMessageBuffer[i][0] = NULL;
         connectedUsers[i][0] = NULL;
      }

      // Set timer for sending packets
      call packetsTimer.startPeriodic(200 + (call Random.rand16() % 100));
      
      // Set timer for neighbor discovery
      call neighborTimer.startPeriodic(5000 + (call Random.rand16() % 1000));
      
      // Set timer for routing table broadcast
      call routingTimer.startPeriodic(20000 + (call Random.rand16() % 5000));

      // Add route to self to the routing table
      // *note* destination 0 indicates a route to self.
      call routingTable.mergeRoute(makeRoute(TOS_NODE_ID, 0, 0, MAX_ROUTE_TTL));

      // Set timer for TCP write/read
      call TCPWriteTimer.startPeriodic(TCP_WRITE_TIMER);
      call TCPReadTimer.startPeriodic(TCP_READ_TIMER);
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         //Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   event void packetsTimer.fired() {
      uint16_t nextHop, cost;

      // If there's not packet to be sent, don't do anything
      if (call packetsQueue.size() == 0) {
         return;
      }
      else if (call packetsQueue.size() > 100) {
         dbg(GENERAL_CHANNEL, "Lots of packets here\n");
      }

      // Otherwise, send the first packet in the queue
      sendPackage = call packetsQueue.popfront();

      if (sendPackage.TTL == 0) {
         // Package has expired
         dbg(ROUTING_CHANNEL, "Packet out of time\n");
         return;
      }
      else {
         sendPackage.TTL -= 1;
      }

      if (sendPackage.protocol == PROTOCOL_PING) {
         nextHop = call routingTable.lookup(sendPackage.dest);
         if (nextHop != 0) {
            // There's a known path to the destination
            call Sender.send(sendPackage, nextHop);

            // Print a debug message (this is a requirement for project 2)
            cost = call routingTable.getCost(sendPackage.dest);
            dbg(ROUTING_CHANNEL, "src: %hhu, dest: %hhu, seq: %hhu, next hop: %hhu, cost: %hhu\n", 
                  sendPackage.src, sendPackage.dest, sendPackage.seq, nextHop, cost);
         }
      }
      else if (sendPackage.protocol == PROTOCOL_PINGREPLY) {
         nextHop = call routingTable.lookup(sendPackage.dest);
         if (nextHop != 0) {
            // There's a known path to the destination
            call Sender.send(sendPackage, nextHop);
         }
      }
      else if (sendPackage.protocol == PROTOCOL_BROADCAST) {
         call Sender.send(sendPackage, AM_BROADCAST_ADDR);
      }
      else if (sendPackage.protocol == PROTOCOL_FLOOD) {
         call Sender.send(sendPackage, AM_BROADCAST_ADDR);
      }
      else if (sendPackage.protocol == PROTOCOL_DV) {
         // No need to check for nextHop because the destination is guaranteed to be a neighbor
         call Sender.send(sendPackage, sendPackage.dest);
      }
      else if (sendPackage.protocol == PROTOCOL_TCP) {
         nextHop = call routingTable.lookup(sendPackage.dest);
         if (nextHop != 0) {
            // dbg(TRANSPORT_CHANNEL, "Sending TCP packet, next hop: %hhu\n", nextHop);
            call Sender.send(sendPackage, nextHop);
         }
      }
   }

   event void neighborTimer.fired(){
      // Broadcast a message to all nearby nodes
      //dbg(NEIGHBOR_CHANNEL, "sending ping from %hhu\n", TOS_NODE_ID);
      signal CommandHandler.broadcast(AM_BROADCAST_ADDR, "pinging...\n");
   }

   //The mote's node sends a packet with its routes to its neighbors.
   event void routingTimer.fired() {
      // Send routing table to all neighbors
      uint16_t i, j, temp;
      uint16_t numRoutes, numNeighbors;
      Route* routes;
      uint32_t* neighbors;

      //dbg(ROUTING_CHANNEL, "Sending routing table to neighbors...\n");

      numRoutes = call routingTable.size();
      routes = call routingTable.getTable();
      numNeighbors = call neighborMap.size();
      neighbors = call neighborMap.getKeys();

      makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, MAX_TTL, PROTOCOL_DV, 0, "payload", PACKET_MAX_PAYLOAD_SIZE);

      for (i = 0; i < numRoutes; i++) {
         // Put each route in a separate package(recall the routingTable is an array of Route's)
         
         //fill address starting at .payload with max_payload_size(20) number of null terminators.
         memset(&sendPackage.payload, '\0', PACKET_MAX_PAYLOAD_SIZE);
         //copy route_size(8) bytes from &routes[i] to payload address
         memcpy(&sendPackage.payload, &routes[i], ROUTE_SIZE);
         
         // Send each route individually to all neighbors
         for (j = 0; j < numNeighbors; j++){
            sendPackage.dest = neighbors[j];
            
            // Poison reverse
            if (routes[i].nextHop == neighbors[j]) {
               temp = routes[i].cost;
               routes[i].cost = UNREACHABLE;
               memcpy(&sendPackage.payload, &routes[i], ROUTE_SIZE);
            }

            call packetsQueue.pushback(sendPackage);

            // Revert poison reverse
            if (routes[i].nextHop == neighbors[j]) {
               routes[i].cost = temp;
               memcpy(&sendPackage.payload, &routes[i], ROUTE_SIZE);
            }
         }
      }
   }

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      uint32_t* keys;
      uint16_t i;

      // dbg(GENERAL_CHANNEL, "Packet Received\n");
      if(len==sizeof(pack)){
         pack* myMsg=(pack*) payload;
         dbg(FLOODING_CHANNEL, "Packet Origin: %hhu\n", myMsg->src);
         if(myMsg->src == TOS_NODE_ID && myMsg->dest == 1){
            dbg(P4_DBG_CHANNEL, "RECEIVED PACKET TO SELF TO BEGIN TRANSMISSION\n");
         }
         // dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
         if(myMsg->seq < currentSequence - 100){
            //dbg(P4_DBG_CHANNEL, "Packet out of date...\n");
            return msg;
         }
         
         if(myMsg->protocol == PROTOCOL_PING){
            dbg(ROUTING_CHANNEL, "Ping packet received\n");
            if (myMsg->dest == TOS_NODE_ID) {
               // The ping message is intended for this node
               // Send acknowledgement reply
               signal CommandHandler.pingReply(myMsg->src);
            }
            else {
               // The ping message is intended for another node
               dbg(ROUTING_CHANNEL, "Forwarding it...\n");
               call packetsQueue.pushback(*myMsg);
            }
         }

         else if (myMsg->protocol == PROTOCOL_PINGREPLY) {
            if (myMsg->dest == TOS_NODE_ID) {
               dbg(ROUTING_CHANNEL, "Acknowledgement received\n");
            }
            else {
               dbg(ROUTING_CHANNEL, "Forwarding acknowledgement...\n");
               call packetsQueue.pushback(*myMsg);
            }
         }

         else if (myMsg->protocol == PROTOCOL_BROADCAST) {
            //add neighbor id to hashmap
            //check for new neighbor
            if(!call neighborMap.contains(myMsg->src)){
               call neighborMap.insert(myMsg->src, 1);
               dbg(NEIGHBOR_CHANNEL, "Inserted: %hhu\n", myMsg->src);
            }
            //dbg(NEIGHBOR_CHANNEL, "UPDATING ACTIVENEIGHBORS\n");
            updateNeighbors(myMsg->src);
         }

         else if (myMsg->protocol == PROTOCOL_FLOOD) {
            // If it's a flooding packet, continue the flood
            // Check for duplicate packet first
            if (checkCache(myMsg)) {
               // If it's a duplicate packet, ignore it
               dbg(FLOODING_CHANNEL, "Packet is a duplicate.\n");
               return msg;
            }

            // Add packet to cache
            if (call Cache.isFull()) {
               // If the cache is already full, delete the oldest data
               call Cache.popfront();
            }
            call Cache.pushback(*myMsg);

            if (myMsg->dest != TOS_NODE_ID) {
               // Propagate the signal only if this node is the intended recipient
              signal CommandHandler.flood(myMsg->dest, myMsg->payload);
            }
         }

         else if (myMsg->protocol == PROTOCOL_DV) {
            // Got a routingTable from a neighbor, copy data to newRoute
            Route newRoute;
            memcpy(&newRoute, &myMsg->payload, ROUTE_SIZE);
            //setting nextHop to be from the sender.
            newRoute.nextHop = myMsg->src;
            //merge this node's Routingtable with the new Routingtable.
            call routingTable.mergeRoute(newRoute);
         }
         
         else if (myMsg->protocol == PROTOCOL_TCP) {
            if (myMsg->dest == TOS_NODE_ID) {
               // If this is the intended destination, let the Transport module handle the TCP packet
               dbg(TRANSPORT_CHANNEL, "Received a TCP packet from (%hhu)\n", myMsg->src);
               call Transport.receive(myMsg);
            }
            else {
               // If this is not the intended destination, forward the packet
               call packetsQueue.pushback(*myMsg);
            }
         }

         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      uint16_t nextHop, cost;

      // dbg(GENERAL_CHANNEL, "PING EVENT \n");

      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, currentSequence, payload, PACKET_MAX_PAYLOAD_SIZE);

      call packetsQueue.pushback(sendPackage);
   }

   event void CommandHandler.pingReply(uint16_t destination){
      uint16_t nextHop, cost;

      dbg(GENERAL_CHANNEL, "Replying ACK from %hhu to %hhu \n", TOS_NODE_ID, destination);
      
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PINGREPLY, currentSequence, "ACK", PACKET_MAX_PAYLOAD_SIZE);
      
      call packetsQueue.pushback(sendPackage);
   }

   event void CommandHandler.broadcast(uint16_t destination, uint8_t *payload){
      // dbg(GENERAL_CHANNEL, "BROADCAST EVENT \n");
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_BROADCAST, currentSequence, payload, PACKET_MAX_PAYLOAD_SIZE);
      call packetsQueue.pushback(sendPackage);
   }

   event void CommandHandler.flood(uint16_t destination, uint8_t *payload){
      // dbg(FLOODING_CHANNEL, "FLOODING EVENT \n");
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_FLOOD, currentSequence, payload, PACKET_MAX_PAYLOAD_SIZE);
      call packetsQueue.pushback(sendPackage);
   }

   event void CommandHandler.printNeighbors(){
      uint32_t* keys;
      uint16_t i;

      keys = call neighborMap.getKeys();

      dbg(NEIGHBOR_CHANNEL, "\nCurrent nodeId: %hhu\n", TOS_NODE_ID);
      dbg(NEIGHBOR_CHANNEL, "Neighbor nodeIDs:\n");

      for(i = 0; i < call neighborMap.size(); i++){
         dbg(NEIGHBOR_CHANNEL, "%hhu\n", keys[i]);
      }
      dbg(NEIGHBOR_CHANNEL, "*End nodeIDs*\n");

            
      dbg(NEIGHBOR_CHANNEL, "**Active Neighbor nodeIDs:\n");

      keys = call activeNeighbors.getKeys();
      for(i = 0; i < call activeNeighbors.size(); i++){
         dbg(NEIGHBOR_CHANNEL, "Node:%hhu\tNodeTTL:%hhu\n", keys[i], call neighborMap.get(keys[i]));
      }
      dbg(NEIGHBOR_CHANNEL, "*End Active nodeIDs*\n");

   }

   event void CommandHandler.printRouteTable(){
      call routingTable.printTable();
   }

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   // Designate this node as a server
   event void CommandHandler.setTestServer(uint16_t port){
      socket_t fd;// socket #. note: socket is an entry into a file descriptor table
      socket_addr_t addr; // holds socket port and addr

      dbg(TRANSPORT_CHANNEL, "Test Server %hhu port %hhu\n", TOS_NODE_ID, port);

      //allocate a socket and initialize
      fd = call Transport.socket();
      addr.addr = TOS_NODE_ID;
      addr.port = port;

      //bind the socket# to socket structure
      if (call Transport.bind(fd, &addr) == SUCCESS) {
         dbg(TRANSPORT_CHANNEL,"Server: SUCCESSFULLY bounded address (%hhu) to socket (%hhu)\n", TOS_NODE_ID, fd);
      }
      else {
         //probably fd is a NULL Socket, thus no available sockets to bind
         //thus we must remove a connection
         dbg(TRANSPORT_CHANNEL,"Server: FAILED to bind address (%hhu) to socket (%hhu)\n", TOS_NODE_ID, fd);
      }

      // ask the socket to start listening for incoming TCP packets
      if (call Transport.listen(fd) == SUCCESS) {
         //modified socket state to listen
         dbg(TRANSPORT_CHANNEL, "Server: Listening at socket (%hhu)...\n", fd);
         default_socket = fd;
      }
      else {
         dbg(TRANSPORT_CHANNEL, "Server: FAILED to switch socket(%hhu)'s state to LISTEN...\n", fd);
      }
   }

   // Desginate this node as a client
   event void CommandHandler.setTestClient(uint16_t destination, uint16_t sourcePort, uint16_t destinationPort, uint16_t transfer){
      socket_t socket;
      socket_addr_t sourceAddress, destinationAddress;

      dbg(TRANSPORT_CHANNEL, "Test Client %hhu destination %hhu source port %hhu destination port %hhu transfer %hhu\n", TOS_NODE_ID, destination, sourcePort, destinationPort, transfer);

      sourceAddress.addr = TOS_NODE_ID;
      sourceAddress.port = sourcePort;
      destinationAddress.addr = destination;
      destinationAddress.port = destinationPort;

      socket = call Transport.socket();

      if (call Transport.bind(socket, &sourceAddress) == SUCCESS) {
         dbg(TRANSPORT_CHANNEL,"Client: SUCESSFULLY bounded address(%hhu) to socket (%hhu)\n", TOS_NODE_ID, socket);
         dbg(TRANSPORT_CHANNEL,"Client: Attempting connection from client(%hhu):port(%hhu) to server(%hhu):port(%hhu)...\n",
            TOS_NODE_ID, socket, destination, destinationPort);
         call Transport.connect(socket, &destinationAddress);
         default_socket = socket;
         call TCPWriteTimer.startPeriodic(TCP_WRITE_TIMER);
         bytesToTransfer = transfer;
      }
   }

   event void CommandHandler.closeClient(uint16_t destination, uint16_t sourcePort, uint16_t destPort){
      socket_t socket;
      socket_addr_t srcAddr, destAddr;
      srcAddr.addr = TOS_NODE_ID;
      srcAddr.port = sourcePort;
      destAddr.addr = destination;
      destAddr.port = destPort;

      dbg(TRANSPORT_CHANNEL, "CLIENT[%hhu][%hhu] IS REQUESTING TO CLOSE CONNECTION TO SERVER[%hhu][%hhu]\n",
      TOS_NODE_ID, sourcePort, destination, destPort);
      
      socket = call Transport.findSocket(&srcAddr, &destAddr);
      if(socket != NULL_SOCKET){
         dbg(TRANSPORT_CHANNEL, "SUCCESS: Socket(%hhu) Found!\n", socket);
      }else{
         dbg(TRANSPORT_CHANNEL, "ERROR: Socket not found...\n");
      }
      //got the socket, time to invoke close
      call Transport.close(socket);

   }

   // sends a hello msg to server to establish a chat profile
   // should send TCP packet with data: "hello <usrname>" to server
   event void CommandHandler.hello(char* user, uint16_t clientPort){
      //port and server node is predetermined to be ID[1] P[41]
      socket_t socket;
      socket_addr_t sourceAddress, destinationAddress;
      dbg(P4_DBG_CHANNEL,"CLIENT[%hhu][%hhu] sending hello to [%hhu][%hhu]...\n", TOS_NODE_ID, clientPort, 1, 41);
      //assign username to this node
      memset(username, '\0', SOCKET_BUFFER_SIZE);
      memcpy(username, user, strlen(user)-1);//i dont know where the carriage return is coming from, removing it
      dbg(P4_DBG_CHANNEL, "username set: %s\n", username);
      //generate msg
      memset(messageBuff, '\0', SOCKET_BUFFER_SIZE);
      sprintf(messageBuff, "hello %s %hhu\r\n", username, clientPort);
      bytesToTransfer = strlen(messageBuff);
      dbg(P4_DBG_CHANNEL, "HELLO MESSAGE[%hhu]: %s\n", bytesToTransfer, messageBuff);
      
      //generate a socket
      sourceAddress.addr = TOS_NODE_ID;
      sourceAddress.port = clientPort;
      destinationAddress.addr = 1;
      destinationAddress.port = 41;

      socket = call Transport.socket();
      if(call Transport.bind(socket, &sourceAddress) == SUCCESS) {
         dbg(P4_DBG_CHANNEL, "Attempting to connect from hello...\n");
         call Transport.connect(socket, &destinationAddress);
         default_socket = socket;
         call TCPWriteTimer.startPeriodic(TCP_WRITE_TIMER);
      }
      //call Transport.connect(socket, &destinationAddress);
   }
   
   //send message to server, which will broadcast the msg to all connected users.
   event void CommandHandler.message(char *msg){
      //dbg(APPLICATION_CHANNEL, "Sending a broadcast message to the server...\n");
      if(default_socket != NULL_SOCKET){
         dbg(P4_DBG_CHANNEL, "Sending message...\n");
         //generate the message
         memset(messageBuff, '\0', SOCKET_BUFFER_SIZE);
         sprintf(messageBuff, "msg %s\r\n", msg);
         bytesToTransfer = strlen(messageBuff);
         bytesWrittenSoFar = 0;
         writeToSocket(default_socket);
         call TCPWriteTimer.startPeriodic(TCP_WRITE_TIMER);
         makeTCPPack(&TCPPackage, 0, 41, 0, 0, 0, 5, "Signal Transmit", TCP_PACKET_MAX_PAYLOAD_SIZE);
         //no flags
         TCPPackage.flags = 0;
         makePack(&sendPackage, TOS_NODE_ID, 1, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
         memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
         dbg(P4_DBG_CHANNEL, "Sending package to self to signal sendBuffer transmission...\n");
         if(call Transport.receive(&sendPackage) == SUCCESS){
            dbg(P4_DBG_CHANNEL, "Transmission initiated!\n");
         }
      }else{
         dbg(P4_DBG_CHANNEL, "NO CONNECTION ESTABLISHED...\n");
      }
   }
   //send msg to server, server will forward it to the specified user
   //include sending client's name
   event void CommandHandler.whisper(char *user, char *msg){
      char *token;
      error_t error;
      //dbg(APPLICATION_CHANNEL, "Sending a whisper message to the server...\n");
      if(default_socket != NULL_SOCKET){
         //dbg(P4_DBG_CHANNEL, "Arguments: user:%s , msg:%s\n", user, msg);
         //dbg(APPLICATION_CHANNEL, "Sending Whisper to %s...\n", user);
         //break down the arguments
         token = strtok(user, " ");
         //constuct the message
         memset(messageBuff, '\0', SOCKET_BUFFER_SIZE);
         sprintf(messageBuff, "whisper %s %s\r\n", token, strtok(NULL,"\n"));
         //reset values for writing since new msg
         bytesToTransfer = strlen(messageBuff);
         bytesWrittenSoFar = 0;
         dbg(P4_DBG_CHANNEL, "WHISPER(%hhu): %s\n",bytesToTransfer, messageBuff);
         writeToSocket(default_socket);
         call TCPWriteTimer.startPeriodic(TCP_WRITE_TIMER);//resert timer to write.
         // make an empty packet to signal Transport layer to begin sending
         // packet will determine where to send the message.
         // send packet to itself, src addr/port: 0/0, dest addr/port: 1/41
         makeTCPPack(&TCPPackage, 0, 41, 0, 0, 0, 5, "Signal Transmit", TCP_PACKET_MAX_PAYLOAD_SIZE);
         //no flags
         TCPPackage.flags = 0;
         makePack(&sendPackage, TOS_NODE_ID, 1, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
         memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
         dbg(P4_DBG_CHANNEL, "Sending package to self to signal sendBuffer transmission...\n");
         if(call Transport.receive(&sendPackage) == SUCCESS){
            dbg(P4_DBG_CHANNEL, "Transmission initiated!\n");
         }
      }else{
         dbg(P4_DBG_CHANNEL, "NO CONNECTION ESTABLISHED...\n");
      }
      
      dbg(P4_DBG_CHANNEL, "End of whisper\n");
   }
   
   event void CommandHandler.listusr(){
      //dbg(APPLICATION_CHANNEL, "Requesting user list...\n");
      if (default_socket != NULL_SOCKET) {
         // Reset message buffer
         memset(messageBuff, '\0', SOCKET_BUFFER_SIZE);
         sprintf(messageBuff, "listusr\r\n");
         bytesToTransfer = strlen(messageBuff);
         bytesWrittenSoFar = 0;

         // Write to send buffer
         writeToSocket(default_socket);
         call TCPWriteTimer.startPeriodic(TCP_WRITE_TIMER); // reset timer

         // Send an empty packet to self to start transmission
         makeTCPPack(&TCPPackage, 0, 41, 0, 0, 0, 1, "Signal Transmit", TCP_PACKET_MAX_PAYLOAD_SIZE);
         makePack(&sendPackage, TOS_NODE_ID, 1, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
         memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
         dbg(P4_DBG_CHANNEL, "Sending package to self to signal sendBuffer transmission...\n");
         if (call Transport.receive(&sendPackage) == SUCCESS) {
            dbg(P4_DBG_CHANNEL, "Transmission initiated!\n");
         }
      }
      else {
         dbg(P4_DBG_CHANNEL, "NO CONNECTION ESTABLISHED...\n");
      }
   }

   event void TCPWriteTimer.fired() {
      writeToSocket(default_socket);
   }

   // Write current content of messageBuff to the specified socket
   void writeToSocket(socket_t fd){
      uint16_t i, num, bytesToWrite;

      bytesToWrite = bytesToTransfer - bytesWrittenSoFar;
      if (bytesToWrite == 0) {
         // No bytes to write
         return;
      }
      else if (bytesToWrite > SOCKET_BUFFER_SIZE) {
         // Limit the amount of numbers written to the maximum space available
         bytesToWrite = SOCKET_BUFFER_SIZE;
      }
      
      // Ask the Transport module to write as much as it can
      i = call Transport.write(fd, messageBuff, bytesToWrite);
      bytesWrittenSoFar += i;
   }

   event void TCPReadTimer.fired() {
      //uint8_t buff[SOCKET_BUFFER_SIZE];
      char buff[SOCKET_BUFFER_SIZE];
      uint16_t i, j, k, num, bytesRead, numSockets;
      char letter;
      socket_t fd;

      numSockets = call socketList.size();
      for (i = 0; i < numSockets; i++) {
         fd = call socketList.get(i);
         //dbg(P4_DBG_CHANNEL, "msgPos[fd:%hhu]: %hhu\t BEFORE read()\n", fd, msgPosition[fd]);
         // Read the socket's buffer
         bytesRead = call Transport.read(fd, buff, SOCKET_BUFFER_SIZE);
         //dbg(P4_DBG_CHANNEL, "msgPos[fd:%hhu]: %hhu\t AFTER read()\n", fd, msgPosition[fd]);
         if(bytesWrittenSoFar != 0){
            //dbg(P4_DBG_CHANNEL, "letters written so far: %hhu\n", bytesWrittenSoFar);
         }
         // Print out the numbers

         //could try numbersRead-1 and j++ at the end of if statement in case break; needs to be removed
         k = msgPosition[fd];
         for (j = 0; j < bytesRead; j++) {
            memcpy(&letter, &buff[j], 1);
            dbg(GENERAL_CHANNEL, "Socket(%hhu)-Received letter: [%hhu]->[%c]\twriting to buffer[%hhu + %hhu]\n", fd,letter, letter, k, j);
            fullMessageBuffer[fd][k+j] = buff[j];
            msgPosition[fd]++;
            if(buff[j] == '\r'){
               dbg(P4_DBG_CHANNEL, "Found \\r\n");
               found_r = TRUE;
            }
            if( buff[j] == '\n'){
                  dbg(P4_DBG_CHANNEL, "Found \\n\n");
                  found_n = TRUE;
            }
            if(found_r == TRUE && found_n == TRUE){
               dbg(P4_DBG_CHANNEL, "\nEND OF MSG DETECTED!\n[\\r]&&[\\n]\nMsg Stored: %s\n\n", fullMessageBuffer[fd]);
               //handle full message
               messageHandler(fd);
               //end of message, reset values
               //dbg(P4_DBG_CHANNEL, "\n\nmsgPosition[%hhu]:%hhu is reset to 0\n\n", fd, msgPosition[fd]);
               msgPosition[fd] = 0;
               k = 0;
               found_r = FALSE;
               found_n = FALSE;
               //this assumes 1 message at a time to read per socket
               break;//QUICK FIX SINCE msgPOS keeps incrementing at the end of msg
            }
            /*if(buff[j] == '\r'){
               dbg(P4_DBG_CHANNEL, "Found \\r\n");
               if( buff[j+1] == '\n'){
                  dbg(P4_DBG_CHANNEL, "Found \\n\n");
                  fullMessageBuffer[fd][k+j+1] = buff[j+1];
                  dbg(P4_DBG_CHANNEL, "\nEND OF MSG DETECTED!\n[\\r]&&[\\n]\nMsg Stored: %s\n\n", fullMessageBuffer[fd]);
                  //handle full message
                  messageHandler(fd);
                  //end of message, reset values
                  //dbg(P4_DBG_CHANNEL, "\n\nmsgPosition[%hhu]:%hhu is reset to 0\n\n", fd, msgPosition[fd]);
                  msgPosition[fd] = 0;
                  k = 0;
                  //this assumes 1 message at a time to read per socket
                  break;//QUICK FIX SINCE msgPOS keeps incrementing at the end of msg
               }
            }*/
         }
      }
            //    if(numbersRead != 0)
            // dbg(P4_DBG_CHANNEL, "Done reading from buffer...\n");
   }

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   event error_t Transport.send(pack* package){
      //update the packet seq number
      package->seq = currentSequence + 1;
      //dbg(P4_DBG_CHANNEL, "Sending packet from (%hhu) to (%hhu) payload: %s\n", package->src, package->dest, package->payload);
      call packetsQueue.pushback(*package);
      incrementSequence();
      return SUCCESS;
   }

   event void Transport.addSocket(socket_t fd) {
      call socketList.pushback(fd);
   }

   void messageHandler(socket_t fd){
      char *iterator = NULL, *token = NULL, *temp = NULL;
      socket_t target_fd = NULL_SOCKET;
      bool userFound = FALSE;
      socket_store_t *socketData;
      char tempMessage[SOCKET_BUFFER_SIZE];
      char space = ' ', comma = ',', returnchr = '\r', newlinechr = '\n';
      uint32_t keys, i;
      bool firstUser = TRUE;
      memcpy(tempMessage, fullMessageBuffer[fd], SOCKET_BUFFER_SIZE);
      //depending on message, execute the following actions
      dbg(P4_DBG_CHANNEL, "Analyzing message: %s\n", tempMessage);
      //"hello", map socket number to username.
      token = strtok(tempMessage, " ");//tokenizing by spaces
      if(strcmp(token, "hello")  == 0){
         token = strtok(NULL, " ");//get next token (username)
         dbg(P4_DBG_CHANNEL, "Found \"hello\"!\nMapping socket[%hhu] to value[%s]\n", fd, token);
         dbg(APPLICATION_CHANNEL, "User registered: %s\n", token);
         memcpy(connectedUsers[fd], token, strlen(token)+1);
         //not doing anything with message, clearing
         memset(fullMessageBuffer[fd], '\0', SOCKET_BUFFER_SIZE);
      }
      else if(strcmp(token, "whisper") == 0){
         token = strtok(NULL, " ");//intended receivername, connectedUsers[fd] is sender name
         temp = strtok(NULL,"");//message
         //forward message
         dbg(P4_DBG_CHANNEL, "Found \"whisper\" from %s to %s\nMSG:%s\n", connectedUsers[fd], token, temp);
         dbg(APPLICATION_CHANNEL, "Whispering to %s: %s", token, temp);
         //modify the message in format: whisper <sender>: <msg>
         sprintf(messageBuff, "whisperFrom %s %s", connectedUsers[fd], temp);
         dbg(P4_DBG_CHANNEL, "Modified message: %s\nInitiating transmission...\n", messageBuff);
         //prepare for transmission
         bytesToTransfer = strlen(messageBuff);
         bytesWrittenSoFar = 0;
         //find the socket with the intended receiver and change it to the default socket
         for(i=0; i < MAX_NUM_OF_SOCKETS; i++){
            if(strcmp(connectedUsers[i], token) == 0){
               target_fd = i;
               dbg(P4_DBG_CHANNEL, "%s is connected to socket[%hhu]\n", token, target_fd);
               break;
            }
         }
         if (target_fd == NULL_SOCKET) {
            dbg(APPLICATION_CHANNEL, "User %s does not exist\n", token);
            return;
         }
         default_socket = target_fd;
         writeToSocket(default_socket);
         call TCPWriteTimer.startPeriodic(TCP_WRITE_TIMER);//resert timer to write.
         // make an empty packet to signal Transport layer to begin sending
         // packet will determine where to send the message.
         // destination is target_fd's src
         socketData = call Transport.getSocketByFd(target_fd);
         makeTCPPack(&TCPPackage, 0, socketData->dest.port, 0, 0, 0, 5, "Sig. Transmit", TCP_PACKET_MAX_PAYLOAD_SIZE);
         makePack(&sendPackage, 0, socketData->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
         memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
         dbg(P4_DBG_CHANNEL, "Sending package to self to signal sendBuffer transmission...\n");
         if(call Transport.receive(&sendPackage) == SUCCESS){
            dbg(P4_DBG_CHANNEL, "Whisper: Transmission initiated to target user!\n");
         }
      }
      else if(strcmp(token, "whisperFrom") == 0) {
         token = strtok(NULL, " ");
         temp = strtok(NULL, "");
         dbg(APPLICATION_CHANNEL, "Received a whisper from %s: %s", token, temp);
      }
      else if(strcmp(token, "msg") == 0){
         temp = strtok(NULL,""); // the message
         dbg(P4_DBG_CHANNEL, "Found \"msg\", message: %s\n", temp);
         
         //modify the message
         memset(messageBuff, '\0', SOCKET_BUFFER_SIZE);
         sprintf(messageBuff, "msgFrom %s %s", connectedUsers[fd], temp);
         dbg(P4_DBG_CHANNEL, "modified message: %s\n", messageBuff);

         //transmit the msg to all users
         for(i=0;i<MAX_NUM_OF_SOCKETS; i++){
            if(connectedUsers[i][0] != NULL){
               if(strcmp(connectedUsers[i], connectedUsers[fd]) != 0){
                  dbg(P4_DBG_CHANNEL, "**Sending modified message to %s over socket(%hhu)**\n\n", connectedUsers[i], i);
                  dbg(APPLICATION_CHANNEL, "Sending a message to %s: %s", connectedUsers[i], temp);
                  //send mesage to this socket
                  target_fd = i;
                  default_socket = target_fd;
                  socketData = call Transport.getSocketByFd(target_fd);
                  bytesToTransfer = strlen(messageBuff); 
                  bytesWrittenSoFar = 0;
                  writeToSocket(target_fd);
                  makeTCPPack(&TCPPackage, 0, socketData->dest.port, 0, 0, 0, SOCKET_BUFFER_SIZE, "Sig. Transmit", TCP_PACKET_MAX_PAYLOAD_SIZE);
                  //no flags
                  TCPPackage.flags = 0;
                  makePack(&sendPackage, 0, socketData->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
                  memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
                  dbg(P4_DBG_CHANNEL, "Sending package to self to signal sendBuffer transmission...\n");
                  if(call Transport.receive(&sendPackage) == SUCCESS){
                     dbg(P4_DBG_CHANNEL, "Whisper: Transmission initiated to target user!\n");
                  }
               }
            }
         }
      }
      else if(strcmp(token, "msgFrom") == 0) {
         token = strtok(NULL, " ");
         temp = strtok(NULL, "");
         dbg(APPLICATION_CHANNEL, "Received a message from %s: %s", token, temp);
      }
      else if(strcmp(tempMessage, "listusr\r\n") == 0){
         dbg(P4_DBG_CHANNEL, "Found \"listusr\" from %s\n", connectedUsers[fd]);
         // Write a reply containing the list of all connected users
         memset(messageBuff, '\0', SOCKET_BUFFER_SIZE);
         sprintf(messageBuff, "listUsrRply");
         for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (connectedUsers[i][0] != NULL) {
               if (firstUser == FALSE) {
                  strncat(messageBuff, &comma, 1);
               }
               else {
                  firstUser = FALSE;
               }
               strncat(messageBuff, &space, 1);
               strcat(messageBuff, connectedUsers[i]);
            }
         }
         strncat(messageBuff, &returnchr, 1);
         strncat(messageBuff, &newlinechr, 1);
         dbg(P4_DBG_CHANNEL, "message: %s\n", messageBuff);
         bytesToTransfer = strlen(messageBuff);
         bytesWrittenSoFar = 0;

         // Write the message to send buffer
         default_socket = fd;
         writeToSocket(default_socket);
         call TCPWriteTimer.startPeriodic(TCP_WRITE_TIMER); // reset timer

         // Send a packet to self to start transmission
         socketData = call Transport.getSocketByFd(fd);
         makeTCPPack(&TCPPackage, socketData->src.port, socketData->dest.port, 0, 0, 0, socketData->bufferSpace, "Signal", TCP_PACKET_MAX_PAYLOAD_SIZE);
         makePack(&sendPackage, socketData->src.addr, socketData->dest.addr, MAX_TTL, PROTOCOL_TCP, 0, "", PACKET_MAX_PAYLOAD_SIZE);
         memcpy(&sendPackage.payload, &TCPPackage, PACKET_MAX_PAYLOAD_SIZE);
         dbg(P4_DBG_CHANNEL, "Sending package to self to signal sendBuffer transmission...\n");
         if (call Transport.receive(&sendPackage) == SUCCESS) {
            dbg(P4_DBG_CHANNEL, "Transmission initiated!\n");
         }
      }
      else if (strcmp(token, "listUsrRply") == 0) {
         temp = strtok(NULL, "");
         dbg(APPLICATION_CHANNEL, "Received a list of users: %s", temp);
      }

      // clear message buffer
      memset(fullMessageBuffer[fd], '\0', SOCKET_BUFFER_SIZE);

      //to debug
      //keys = call userMap.getKeys();
      dbg(P4_DBG_CHANNEL, "\n\n**CURRENT CONNECTED USERS:**\n");
      for(i = 0; i < MAX_NUM_OF_SOCKETS; i++){
         if(connectedUsers[i][0] != NULL){
            dbg(P4_DBG_CHANNEL,"socket[%hhu]->[%s]\n", i, connectedUsers[i]);
         }
      }
       dbg(P4_DBG_CHANNEL, "\n**END OF CONNECTED USERS**\n\n");


   }

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
      incrementSequence();//dont forget to increment sequence.
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

   bool checkCache(pack *Package) {
      uint16_t cacheSize = call Cache.size();
      uint16_t i;
      for (i = 0; i < cacheSize; i++) {
         if (samePack(*Package, call Cache.get(i))) {
            return TRUE;
         }
      }
      return FALSE;
   }

   void incrementSequence() {
      currentSequence = (currentSequence + 1) % MAX_SEQUENCE_NUMBER;
   }
   void updateNeighbors(uint16_t src){
      #define MAX_NEIGHBOR_TTL 20
      uint16_t tempVal, i;
      uint32_t *keys;
      
      //dbg(NEIGHBOR_CHANNEL, "\n****UPDATING ACTIVE NEIGHBORS****\nCurrent nodeId: %hhu\n", TOS_NODE_ID);
      //decrements all values in neighborMap, updates src to max TTL
      keys = call neighborMap.getKeys();
      for(i = 0; i < call neighborMap.size(); i++){
         //check if source
         if(keys[i] != src){
            //decrement everything else > 0
            tempVal = call neighborMap.get(keys[i]);
            if(tempVal > 0){
               tempVal--;
            }
            //update TTL value
            call neighborMap.set(keys[i], tempVal);
         }
         //updating the src node values
         call neighborMap.set(src, MAX_NEIGHBOR_TTL);
      }
      //update activeNeighbors. only holds node info, not TTL
      for(i = 0; i < call neighborMap.size(); i++){
         if(call neighborMap.get(keys[i]) > 0){
            //this node is active
            if(!call activeNeighbors.contains(keys[i])){
               call activeNeighbors.insert(keys[i], 0);
            }
         }else{
            //inactive node, remove
            call activeNeighbors.remove(keys[i]);
         }
      }

   }
}
