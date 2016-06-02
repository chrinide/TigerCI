! This Source Code Form is subject to the terms of the Mozilla Public
! License, v. 2.0. If a copy of the MPL was not distributed with this
! file, You can obtain one at http://mozilla.org/MPL/2.0/.
module iajk_mod
use IOBuffer
use c_sort_finterface
contains
  subroutine make_iajk(cho_data)
    ! A subroutine to construct the (ia|jk) integrals for the sigmavector routines

    use global_var_mod
    use molecule_var_mod
    use cholesky_structs
    use wp_tov_mod
    use sort_utils
    use io_unit_numbers
#ifdef TIGER_USE_OMP
    use omp_lib
#endif

    implicit none

    integer::a,c,d ! orbital indices
    integer::i,j,k
    integer::max_ia
    integer::i1,a1
    integer::ij_ind,ak_ind
    integer::ia_count,ia_count2,ia_count3,ak_count
    integer::icount      
    integer::idum,idum2,idum3
    integer::ij_pairs,ia_pairs
    integer::rec_count,rec_count2
    integer::block_len
    integer::block_size,max_block_size
    integer::allocatestatus,deallocatestatus 
    integer,dimension(num_internal,num_internal)::ij_block
    integer,dimension(:),allocatable::i_ind,a_ind,ij_step!,iajk_bl_vec
    integer::imax
    integer,dimension(:),allocatable::ivec,ivec2,ivec3

    real(real8),allocatable,dimension(:,:)::ia_cho
    real(real8),allocatable,dimension(:)::rvec
    real(real8),dimension(numcho)::jk_vec

    logical::transform_int  ! Decides if we need to transform integrals
    type(cholesky_data)::cho_data
    integer::threadID

#ifdef TIGER_USE_OMP
    threadID = OMP_get_thread_num()+1
#else
    threadID = 1
#endif

    ! START AUTOGENERATED INITIALIZATION 
    block_len = 0
    idum = 0
    ij_pairs = 0
    ia_count3 = 0
    allocatestatus = 0
    ia_pairs = 0
    block_size = 0
    max_block_size = 0
    deallocatestatus = 0
    ij_block = 0
    rec_count2 = 0
    icount = 0
    jk_vec = 0.0
    idum3 = 0
    idum2 = 0
    imax = 0
    ak_count = 0
    ia_count2 = 0
    rec_count = 0
    a1 = 0
    max_ia = 0
    ak_ind = 0
    ia_count = 0
    transform_int = .false.
    i1 = 0
    a = 0
    c = 0
    d = 0
    ij_ind = 0
    i = 0
    j = 0
    k = 0
    ! END AUTOGENERATED INITIALIZATION 
    !*******************************************************************************

    ij_pairs = 0  ! Number of kept (ij) pairs
    ij_block = 0  ! Number of (ia|jk) integrals in each (ij) block
    ak_count = 0

    do i = 1,num_internal
       do j = 1,i-1

          if (ignorable_pair(i,j) ) cycle

          ij_pairs = ij_pairs + 1 
          ak_count = 0 

          do k = 1, num_internal
             if (ignorable_pair(i,k) ) cycle
             if (ignorable_pair(j,k) ) cycle

             do a = num_internal+1,num_orbitals
                if (ignorable_pair(i,a) ) cycle
                if (ignorable_pair(j,a) ) cycle
                if (ignorable_pair(k,a) ) cycle

                ak_count = ak_count + 1

             enddo
          enddo
          ij_block(i,j) = ak_count ! # of (ia|jk) integrals in this (ij) block
       enddo
    enddo

    !allocate(iajk_bl_vec(ij_pairs),stat=allocatestatus)

    ! Record block size before cumulative counter

    idum3 = 0
    max_block_size = 0 
    do i = 1, num_internal
       do j = 1,i-1

          if (ignorable_pair(i,j) ) cycle

          idum = ij_block(i,j) 
          idum2= i*(i-1)/2+j
          write(unit=iajk_bl_no,rec=idum2) idum 
          if (idum .gt. max_block_size) max_block_size = idum 
          idum3 = idum3 + idum

       enddo
    enddo

    icount = 0 
    do i = 1,num_internal
       do j = 1,i-1
          if (ij_block(i,j) .eq. 0) cycle
          idum = ij_block(i,j)
          ij_block(i,j) = icount 
          icount = icount + idum 
       enddo
    enddo

    ! Count # of (ia) pairs
    ia_pairs = 0
    do i = 2,num_internal
       do a = num_internal+1,num_orbitals
          if (ignorable_pair(i,a) ) cycle
          ia_pairs = ia_pairs + 1
       enddo
    enddo


    !******************************************************************************
    ! Set a maximum buffer size
    max_ia = int(max_mem_ints/numcho)
    max_ia = max_ia - 1

    !******************************************************************************
    inquire(iolength=idum) number_bas
    open(unit=367,file=scratch_directory // 'scr_ind.dat',access='direct',recl=idum,form='unformatted')

    !  allocate(ia_cho(max_ia,numcho),stat=allocatestatus)
    allocate(ia_cho(numcho,max_ia),stat=allocatestatus)
    allocate(i_ind(max_ia),stat=allocatestatus)
    allocate(a_ind(max_ia),stat=allocatestatus)
    allocate(ij_step(num_internal*(num_internal+1)/2),stat=allocatestatus) ! Is max_ia the correct size?
    ij_step = 0 ! To keep the offset position of each ic block on disk

    allocate(rvec(max_ia),stat=allocatestatus)
    allocate(ivec(max_ia),ivec2(max_ia),stat=allocatestatus)

    !******************************************************************************
    ! Construct the (ia|jk) integrals. Buffered version.
    ! Step 1: Read max block of (ia) buffer
    ! Step 2: Go to work construct all (ia|jk) integrals with (ia) block. 
    ! Step 3: Get new (ia) block and repeat till all (ia) blocks are exhausted
    ! Step 4: Resort (ia|jk) 

    transform_int = .false.

    ia_count = 0           
    ia_count2 = 0    
    ia_count3 = 0
    rec_count = 0
    rec_count2 = 0
    block_len = 0

    idum3 = 0

    do i = 2,num_internal
       imax = i
       do a = num_internal+1,num_orbitals
          if (ignorable_pair(i,a) ) cycle

          idum = a*(a-1)/2+i
          idum = cho_data%mo_ind_inv(idum)

          ! Read in max {ia} block   

          ia_count = ia_count + 1   ! For counting ia_index in (ia) buffer
          ia_count2 = ia_count2 + 1 ! Actual progress of ia loop

          if (idum .ne. 0) then
             call for_double_buf_readblock(mo_int_no, idum, ia_cho(1:numcho,ia_count),threadID)
             !read(unit=mo_int_no,rec=idum) ia_cho(1:numcho,ia_count)
          endif

          i_ind(ia_count) = i
          a_ind(ia_count) = a

          if (ia_count .eq. max_ia) then ! Buffer is now full or everything has been read into buffer
             transform_int = .true.   ! Go to transform integrals portion because buffer is full
             block_len = max_ia
          endif

          if (ia_count2 .eq. ia_pairs) then ! Everything has been read into buffer
             transform_int = .true.   ! Go to transform integrals portion because buffer is full
             block_len = ia_count 
          endif


          !*************************************************************************************** 
          if (transform_int) then ! (ia) buffer is full. Use them to construct (ia|jk) integrals

             do j = 1,imax-1 ! We will construct all the (ia|jk) integrals for the current (ia) block

                do k = 1,num_internal

                   if (ignorable_pair(j,k) ) cycle

                   jk_vec = 0.0D0

                   idum = max(j,k)
                   idum = idum*(idum-1)/2+min(j,k)
                   idum = cho_data%mo_ind_inv(idum)

                   if (idum .ne. 0) then
                      call for_double_buf_readblock(mo_int_no, idum, jk_vec(1:numcho),threadID)
                      !read(unit=mo_int_no,rec=idum) jk_vec(1:numcho)
                   endif

                   idum2 = 0
                   ia_count3 = 0
                   rvec = 0.0D0 

                   do d = 1,block_len

                      ia_count3 = ia_count3 + 1
                      i1 = i_ind(ia_count3) 
                      a1 = a_ind(ia_count3)

                      if (j .ge. i1) cycle ! exit ?

                      if (ignorable_pair(i1,j) ) cycle
                      if (ignorable_pair(i1,k) ) cycle 
                      if (ignorable_pair(a1,j) ) cycle
                      if (ignorable_pair(a1,k) ) cycle

                      !                 idum = i1*(i1-1)/2+j
                      !                 if (pprr(idum) .lt. 1.0D-8) cycle


                      ij_ind = (i1)*(i1-1)/2+j  ! cpd index
                      ak_ind = (k-1)*num_orbitals+a1

                      idum2 = idum2 + 1
                      idum3 = idum3 + 1

                      ij_step(ij_ind) = ij_step(ij_ind) + 1 ! Don't misplace this line

                      ivec(idum2) = ij_block(i1,j) + ij_step(ij_ind)

                      ivec2(idum2) = ak_ind

                      rvec(idum2) = dot_product(ia_cho(1:numcho,ia_count3),jk_vec(1:numcho))

                   enddo

                   do c = 1,idum2
                      rec_count = ivec(c)
                      call for_double_buf_writeElement(cd_iajk_no,rec_count,rvec(c),threadID)
                   enddo


                   do c = 1,idum2               ! record cpd indexes
                      rec_count = ivec(c)
                      write(unit=367,rec=rec_count) ivec2(c)
                   enddo

                enddo
             enddo

             transform_int = .false.  ! Reset to false when (ia) buffer is exhausted
             i_ind = 0 
             a_ind = 0
             ia_cho = 0.0D0
             ia_count = 0

          endif ! transform_int
          !********************************************************************************************

       enddo ! a
    enddo ! i

    deallocate(ia_cho,stat=deallocatestatus)
    deallocate(i_ind,stat=deallocatestatus)
    deallocate(a_ind,stat=deallocatestatus)
    deallocate(ij_step,stat=deallocatestatus)
    deallocate(rvec,stat=deallocatestatus)
    deallocate(ivec,ivec2,stat=deallocatestatus)

    ! Now we want to resort the (ia|jk) integrals

    allocate(rvec(max_block_size),stat=allocatestatus)
    rvec = 0.0
    allocate(ivec(max_block_size),ivec2(max_block_size),ivec3(max_block_size),stat=allocatestatus)
    ivec = 0
    ivec2 = 0
    ivec3 = 0
  
    ivec3 = 0
    do i = 1,max_block_size
       ivec3(i) = i
    enddo

    icount = 0
    do i = 1,num_internal
       do j = 1,i-1
          if (ignorable_pair(i,j) ) cycle
          idum2 = i*(i-1)/2+j
          read(unit=iajk_bl_no,rec=idum2) block_size
          do c = 1,block_size
             call for_double_buf_readElement(cd_iajk_no,icount+c,rvec(c),threadID)
          enddo
          do c = 1,block_size
             read(unit=367,rec=icount+c) ivec(c)
          enddo

          ivec2(1:block_size) = ivec3(1:block_size)
          call sort_int_array_with_index(ivec(1:block_size), ivec2(1:block_size))

          do c = 1,block_size ! Write sorted (ia|jk) block
             idum = ivec2(c)
             call for_double_buf_writeElement(cd_iajk_no,icount+c,rvec(idum),threadID)
          enddo

          icount = icount + block_size

       enddo
    enddo

    close(unit=367,status='delete')

    ! Record cumulative block size
    do i = 1,num_internal
       do j = 1,i-1
          if (ignorable_pair(i,j) ) cycle
          idum = i*(i-1)/2+j
          write(unit=iajk_bl_no,rec=idum) ij_block(i,j)  
       enddo
    enddo


    deallocate(rvec,stat=deallocatestatus)
    deallocate(ivec,ivec2,ivec3,stat=deallocatestatus)

  end subroutine make_iajk
end module iajk_mod