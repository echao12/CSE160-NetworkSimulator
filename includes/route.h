#ifndef ROUTE_H
#define ROUTE_H

#define MAX_ROUTING_TABLE_SIZE 256
#define MAX_ROUTE_TTL 120

typedef nx_struct Route {
    nx_uint16_t destination;
    nx_uint16_t nextHop;
    nx_uint16_t cost;
    nx_uint16_t TTL;  // what to do with this?
} Route;

Route makeRoute(nx_uint16_t dest, nx_uint16_t next, nx_uint16_t c, nx_uint16_t ttl) {
    Route newRoute;
    newRoute.destination = dest;
    newRoute.nextHop = next;
    newRoute.cost = c;
    newRoute.TTL = ttl;
    return newRoute;
}

#endif