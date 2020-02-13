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

module Node{
   uses interface Boot;

   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;
   
   uses interface Hashmap<uint16_t> as neighborMap;

   uses interface List<pack> as Cache;

   uses interface Timer<TMilli> as timer0;
}

implementation{
   pack sendPackage;
   uint16_t currentSequence = 0;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   bool checkCache(pack *Package);
   void incrementSequence();

   event void Boot.booted(){
      call AMControl.start();

      dbg(GENERAL_CHANNEL, "Booted\n");
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

   //implement timer0 fired()
   event void timer0.fired(){
      dbg(NEIGHBOR_CHANNEL, "\n\nRepeated: finding neighbors to node %hhu\n\n", TOS_NODE_ID);
      signal CommandHandler.ping(AM_BROADCAST_ADDR, "pinging...\n");
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
            call timer0.startPeriodic(1000);
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

   event void CommandHandler.printRouteTable(){}

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
