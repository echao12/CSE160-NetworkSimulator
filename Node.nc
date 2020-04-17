/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
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
}

implementation{
   pack sendPackage;
   uint16_t currentSequence = 0;

   // TCP-related variables
   socket_t default_socket = NULL_SOCKET;
   uint16_t numbersToTransfer = 0, numbersWrittenSoFar = 0;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   bool checkCache(pack *Package);
   void incrementSequence();
   void updateNeighbors(uint16_t src);

   //TinyOS Boot sequence completed, each mote calls this function.
   event void Boot.booted(){

      call AMControl.start();//start radio

      dbg(GENERAL_CHANNEL, "(%hhu)Booted\n", TOS_NODE_ID);

      // Set timer for sending packets
      call packetsTimer.startPeriodic(200 + (call Random.rand16() % 50));
      
      // Set timer for neighbor discovery
      call neighborTimer.startPeriodic(4000 + (call Random.rand16() % 2000));
      
      // Set timer for routing table broadcast
      call routingTimer.startPeriodic(10000 + (call Random.rand16() % 5000));

      // Add route to self to the routing table
      // *note* destination 0 indicates a route to self.
      call routingTable.mergeRoute(makeRoute(TOS_NODE_ID, 0, 0, MAX_ROUTE_TTL));
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
         // dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
         
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
         call TCPReadTimer.startPeriodic(TCP_READ_TIMER);
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
         numbersToTransfer = transfer;
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

   event void TCPWriteTimer.fired() {
      // Create an array and fill it with numbers
      uint8_t buff[SOCKET_BUFFER_SIZE];
      uint16_t i, num, numbersToWrite;

      numbersToWrite = numbersToTransfer - numbersWrittenSoFar;
      if (numbersToWrite == 0) {
         // All numbers have been written
         return;
      }
      else if (numbersToWrite > SOCKET_BUFFER_SIZE/2) {
         // Limit the amount of numbers written to the maximum space available
         numbersToWrite = SOCKET_BUFFER_SIZE/2;
      }

      // Fill the array with numbers
      for (i = 0; i < numbersToWrite; i++) {
         num = numbersWrittenSoFar + i + 1;
         memcpy(&buff[i*2], &num, 2);
      }

      // Ask the Transport module to write as much as it can
      i = call Transport.write(default_socket, buff, numbersToWrite*2);
      numbersWrittenSoFar += i/2;
   }

   event void TCPReadTimer.fired() {
      // TODO: Figure out what to do in case there are multiple receiver sockets

      uint8_t buff[SOCKET_BUFFER_SIZE];
      uint16_t i, num, numbersRead;

      // Read the socket's buffer
      numbersRead = call Transport.read(default_socket, buff, SOCKET_BUFFER_SIZE) / 2;

      // Print out the numbers
      for (i = 0; i < numbersRead; i++) {
         memcpy(&buff[i*2], &num, 2);
         dbg(TRANSPORT_CHANNEL, "Received number: %hhu\n", num);
      }
   }

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   event error_t Transport.send(pack* package){
      //update the packet seq number
      package->seq = currentSequence + 1;
      dbg(TRANSPORT_CHANNEL, "Sending packet from (%hhu) to (%hhu)\n", package->src, package->dest);
      call packetsQueue.pushback(*package);
      incrementSequence();
      return SUCCESS;
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
