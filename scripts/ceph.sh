#!/bin/bash

# Converted from ceph.nu

main_ceph_status() {
    kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
}

main_ceph_cluster() {
    kubectl --namespace rook-ceph get cephcluster rook-ceph
}

main_ceph_delete() {
    kubectl --namespace rook-ceph patch cephcluster rook-ceph --type merge -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}'
    kubectl delete storageclasses ceph-block ceph-bucket ceph-filesystem
    kubectl --namespace rook-ceph delete cephblockpools ceph-blockpool
    kubectl --namespace rook-ceph delete cephobjectstore ceph-objectstore
    kubectl --namespace rook-ceph delete cephfilesystem ceph-filesystem
}