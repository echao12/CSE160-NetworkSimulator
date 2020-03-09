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

module Node{
   uses interface Boot;

   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;
   
   uses interface Hashmap<uint16_t> as neighborMap;

   uses interface List<pack> as Cache;

   uses interface List<pack> as packetsQueue;

   uses interface RoutingTable as routingTable;

   uses interface Timer<TMilli> as packetsTimer;
   uses interface Timer<TMilli> as timer0;
   uses interface Timer<TMilli> as routingTimer;
   uses interface Random as Random;
}

implementation{
   pack sendPackage;
   uint16_t currentSequence = 0;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   bool checkCache(pack *Package);
   void incrementSequence();

   //TinyOS Boot sequence completed, each mote calls this function.
   event void Boot.booted(){

      call AMControl.start();//start radio

      dbg(GENERAL_CHANNEL, "(%hhu)Booted\n", TOS_NODE_ID);

      // Set timer for sending packets
      call packetsTimer.startPeriodic(25 + (call Random.rand16() % 25));
      
      // Set timer for neighbor discovery
      call timer0.startPeriodic(1000 + (call Random.rand16() % 4000));
      
      // Set timer for routing table broadcast
      call routingTimer.startPeriodic(5000 + (call Random.rand16() % 1000));

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
      // If there's not packet to be sent, don't do anything
      if (call packetsQueue.size() == 0) {
         return;
      }

      // Otherwise, send the first packet in the queue
      sendPackage = call packetsQueue.popfront();
      if (sendPackage.protocol == PROTOCOL_PING) {
         call Sender.send(sendPackage, sendPackage.dest);
      }
      else if (sendPackage.protocol == PROTOCOL_PINGREPLY) {
         call Sender.send(sendPackage, sendPackage.dest);
      }
      else if (sendPackage.protocol == PROTOCOL_BROADCAST) {
         call Sender.send(sendPackage, AM_BROADCAST_ADDR);
      }
      else if (sendPackage.protocol == PROTOCOL_FLOOD) {
         call Sender.send(sendPackage, AM_BROADCAST_ADDR);
      }
      else if (sendPackage.protocol == PROTOCOL_DV) {
         call Sender.send(sendPackage, sendPackage.dest);
      }
   }

   event void timer0.fired(){
      // Broadcast a message to all nearby nodes
      //dbg(NEIGHBOR_CHANNEL, "sending ping from %hhu\n", TOS_NODE_ID);
      signal CommandHandler.ping(AM_BROADCAST_ADDR, "pinging...\n");
   }

   //The mote's node sends a packet with its routes to its neighbors.
   event void routingTimer.fired() {
      // Send routing table to all neighbors
      uint16_t i, j;
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
            call packetsQueue.pushback(sendPackage);
         }
      }

      for(i = 0; i < call neighborMap.size(); i++){
         signal CommandHandler.ping(neighbors[i], "hello there");
      }
   }

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      uint32_t* keys;
      uint16_t i;

      dbg(GENERAL_CHANNEL, "Packet Received\n");
      if(len==sizeof(pack)){
         pack* myMsg=(pack*) payload;
         dbg(FLOODING_CHANNEL, "Packet Origin: %hhu\n", myMsg->src);
         dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);

         //add neighbor id to hashmap
         //check for new neighbor
         if(!call neighborMap.contains(myMsg->src)){
            call neighborMap.insert(myMsg->src, 1);
            dbg(NEIGHBOR_CHANNEL, "Inserted: %hhu\n", myMsg->src);
         }
         
         //ping reply
         if(myMsg->protocol == PROTOCOL_PING){
            //set timer to broadcast to neighbors every second
            //call timer0.startPeriodic((1000 + call Random.rand16()) % 5000);
            //send acknowledgement reply
            signal CommandHandler.pingReply(myMsg->src);
         }

         // If it's a flooding packet, continue the flood
         if (myMsg->protocol == PROTOCOL_FLOOD) {
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

         if (myMsg->protocol == PROTOCOL_DV) {
            // Got a routingTable from a neighbor, copy data to newRoute
            Route newRoute;
            memcpy(&newRoute, &myMsg->payload, ROUTE_SIZE);
            //setting nextHop to be from the sender.
            newRoute.nextHop = myMsg->src;
            //merge this node's Routingtable with the new Routingtable.
            call routingTable.mergeRoute(newRoute);
         }

         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "PING EVENT \n");
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, currentSequence, payload, PACKET_MAX_PAYLOAD_SIZE);
      incrementSequence();
      call Sender.send(sendPackage, destination);
   }

   event void CommandHandler.pingReply(uint16_t destination){
      dbg(GENERAL_CHANNEL, "Replying ACK from %hhu to %hhu \n", TOS_NODE_ID, destination);
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PINGREPLY, currentSequence, "ACK", PACKET_MAX_PAYLOAD_SIZE);
      incrementSequence();
      call Sender.send(sendPackage, destination);
   }

   event void CommandHandler.broadcast(uint16_t destination, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "BROADCAST EVENT \n");
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, currentSequence, payload, PACKET_MAX_PAYLOAD_SIZE);
      incrementSequence();
      call Sender.send(sendPackage, AM_BROADCAST_ADDR);
   }

   event void CommandHandler.flood(uint16_t destination, uint8_t *payload){
      dbg(FLOODING_CHANNEL, "FLOODING EVENT \n");
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_FLOOD, currentSequence, payload, PACKET_MAX_PAYLOAD_SIZE);
      incrementSequence();
      call Sender.send(sendPackage, AM_BROADCAST_ADDR);
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
   }

   event void CommandHandler.printRouteTable(){
      call routingTable.printTable();
   }

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(){}

   event void CommandHandler.setTestClient(){}

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
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
}
