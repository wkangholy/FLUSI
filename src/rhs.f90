! Wrapper for computing the nonlinear source term for Navier-Stokes/MHD
subroutine cal_nlk(time,it,nlk,uk,u,vort,work,workc,press)
  use fsi_vars
  use p3dfft_wrapper
  implicit none

  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw) 
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(in) :: time
  real(kind=pr) :: t1,t0
  integer, intent(in) :: it
  t0 = MPI_wtime()
  
  select case(method)
  case("fsi") 
    !---------------------------------------------------------------------------
    ! FSI case. note projection is outsourced and performed here. 
    !---------------------------------------------------------------------------
    ! compute source-terms, *not* divergence-free
    t1 = MPI_wtime()
    call cal_nlk_fsi(time,it,nlk,uk,u,vort,work,workc)
    time_nlk2 = time_nlk2 + MPI_wtime() - t1 
    
    t1 = MPI_wtime()   
    ! if we compute active FSI (with flexible obstacles), we need the pressure
    if (use_solid_model=="yes") then
      call pressure( nlk,workc(:,:,:,1) )
      ! transform it to phys space (note "press" has ghostpoints, cut them here)
      call ifft( ink=workc(:,:,:,1), outx=press(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3)) )
    endif
    ! project the right hand side to the incompressible manifold
    call add_grad_pressure(nlk(:,:,:,1),nlk(:,:,:,2),nlk(:,:,:,3))
    ! for global performance measurement
    time_p = time_p + MPI_wtime() - t1 
    
    !---------------------------------------------------------------------------
    ! passive scalar (currently only one) the work array vort is now free
    ! so use it in cal_nlk_scalar
    !---------------------------------------------------------------------------
    t1 = MPI_wtime()
    if ((use_passive_scalar==1).and.(compute_scalar)) then
      call cal_nlk_scalar(time,it,u,uk(:,:,:,4),nlk(:,:,:,4),workc(:,:,:,1),vort)
    endif
    time_nlk_scalar = time_nlk_scalar + MPI_wtime() - t1
    
  case("mhd") 
     !--------------------------------------------------------------------------
     ! MHD case
     !--------------------------------------------------------------------------
     call cal_nlk_mhd(nlk,uk,u,vort)
     
  case default
     if (mpirank == 0) write(*,*) "Error! Unkonwn method in cal_nlk"
     call abort()
  end select
  
  time_rhs = time_rhs + MPI_wtime() - t0
end subroutine cal_nlk


!-------------------------------------------------------------------------------
! Compute the nonlinear source term of the Navier-Stokes equation,
! including penalty term, in Fourier space. Seven real-valued
! arrays are required for working memory. The term in NLK reads
! nlk = omega x u - chi/eta * (u-us) - sponge
! Input:
!       time: guess what!
!       uk: vector field of velocity in Fourier space, holding the 3 velocity
!           components and the passive scalar, if present
! Output:
!       nlk:  The right hand side of penalized Navier-Stokes in Fourier space,
!             ie the NL term, penalty term, sponge term (NOT THE PRESSURE)
!       vort: work array, can be reused immediatly (is free after this routine)
!       u:    work array, contains the velocity in phys space this is reused in 
!             the caller FluidTimestep to adjust dt
!       work: work array (real)
!       workc: work array (cmplx), for sponge and/or passive scalar
!
! NOTES:
!       16 Jul 2014: This routine excludes the pressure. the field NLK is
!          NOT DIVERGENCE FREE. The projection takes place in the
!          caller "cal_nlk"
!       09 Aug 2014: enable dynamic mean flow forcing. this solves the eqn 
!          d(u_mean)/dt = F / m_fluid
!          This is useful if one wants the mean flow to be independend of the 
!          domain size. It accelerates a given mass of fluid, which is fixed.
!          Solving this eqn requires to compute the sum of the penalty term
!          in this routine, which is dead weight when not using this function.
!-------------------------------------------------------------------------------
subroutine cal_nlk_fsi(time,it,nlk,uk,u,vort,work,workc)
  use mpi
  use p3dfft_wrapper
  use fsi_vars
  use basic_operators
  use penalization ! mask array etc
  
  implicit none

  real(kind=pr),intent (in) :: time
  integer, intent(in) :: it
  complex(kind=pr),intent(in)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(out)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw) 
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr) :: t0,t1,ux,uy,uz,vorx,vory,vorz,chi,usx,usy,usz
  real(kind=pr) :: fx,fy,fz,fx1,fy1,fz1
  real(kind=pr) :: soft_startup
  integer :: ix,iz,iy,mpicode
  t0 = MPI_wtime()
  fx=0.d0; fy=0.d0; fz=0.d0

  !-----------------------------------------------------------------------------
  !-- Calculate velocity in physical space
  !-----------------------------------------------------------------------------
  t1 = MPI_wtime()
  call ifft3 (outx=u, ink=uk)
  time_u = time_u + MPI_wtime() - t1
  
  !-----------------------------------------------------------------------------
  !-- Compute vorticity
  !-----------------------------------------------------------------------------
  t1 = MPI_wtime()
  ! nlk is temporarily used for vortk
  call curl ( ink=uk, outk=nlk )
  ! transform it to physical space
  call ifft3 ( ink=nlk, outx=vort)  
  time_vor = time_vor + MPI_wtime() - t1  
  
  !-----------------------------------------------------------------------------
  !-- vorticity sponge term
  !-----------------------------------------------------------------------------
  t1 = MPI_wtime()
  call vorticity_sponge( vort, work(:,:,:,1), workc )
  time_sponge = time_sponge + MPI_wtime() - t1
    
  !-----------------------------------------------------------------------------
  !-- Non-Linear terms
  !-----------------------------------------------------------------------------
  t1 = MPI_wtime()
  do iz=ra(3),rb(3)
    do iy=ra(2),rb(2)
      do ix=ra(1),rb(1)
        ! local loop variables
        ux   = u(ix,iy,iz,1)
        uy   = u(ix,iy,iz,2)
        uz   = u(ix,iy,iz,3)
        vorx = vort(ix,iy,iz,1)
        vory = vort(ix,iy,iz,2)
        vorz = vort(ix,iy,iz,3)
        
        ! local variables for penalization
        chi = mask(ix,iy,iz)          
        usx = us(ix,iy,iz,1)
        usy = us(ix,iy,iz,2)
        usz = us(ix,iy,iz,3)
        
        ! compute sum of penalty term while computing it
        fx = fx + chi*(ux-usx)
        fy = fy + chi*(uy-usy)
        fz = fz + chi*(uz-usz)
        
        ! we overwrite the vorticity with the NL terms in phys space
        ! note this is indeed -(vor x u) (negative sign)
        vort(ix,iy,iz,1) = uy*vorz - uz*vory -chi*(ux-usx)
        vort(ix,iy,iz,2) = uz*vorx - ux*vorz -chi*(uy-usy)
        vort(ix,iy,iz,3) = ux*vory - uy*vorx -chi*(uz-usz)
      enddo
    enddo
  enddo
  ! to Fourier space
  call fft3( inx=vort,outk=nlk )  
  time_curl = time_curl + MPI_wtime() - t1  
  
  !-----------------------------------------------------------------------------
  ! add sponge term
  !-----------------------------------------------------------------------------
  t1 = MPI_wtime()
  if (iVorticitySponge == "yes") then
    nlk(:,:,:,1) = nlk(:,:,:,1) + workc(:,:,:,1)
    nlk(:,:,:,2) = nlk(:,:,:,2) + workc(:,:,:,2)
    nlk(:,:,:,3) = nlk(:,:,:,3) + workc(:,:,:,3)
  endif
  time_sponge = time_sponge + MPI_wtime() - t1  
  
  !-----------------------------------------------------------------------------
  ! dynamic mean flow forcing (fix fluid mass manually, domain-independent)
  ! The Mean Flow is governed by the zeroth Fourier mode of the RHS. Note this
  ! is independent of the pressure (since it has vannishing spatial avg).
  ! If the meanflow at t=0 is not 0, the startup singularity in the forces
  ! causes problems. for this case, we use the startup conditioner to keep
  ! the meanflow const until T_release_meanflow, then gently turning it on
  ! during the time tau_meanflow
  !-----------------------------------------------------------------------------
  if(iMeanFlow_x=="dynamic".or.iMeanFlow_y=="dynamic".or.iMeanFlow_z=="dynamic") then 
    ! integral forces:
    fx = fx*dx*dy*dz
    fy = fy*dx*dy*dz
    fz = fz*dx*dy*dz
    call MPI_ALLREDUCE ( fx,fx1,1,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpicode)  
    call MPI_ALLREDUCE ( fy,fy1,1,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpicode) 
    call MPI_ALLREDUCE ( fz,fz1,1,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpicode) 
    
    ! startup conditioner (See vars.f90)
    if (iMeanFlowStartupConditioner=="yes") then
      soft_startup = startup_conditioner(time,T_release_meanflow,tau_meanflow)
      fx1 = fx1*soft_startup
      fy1 = fy1*soft_startup
      fz1 = fz1*soft_startup
    endif
    
    ! fixing the fluid mass means modifying the zero mode of RHS term
    if (ca(1) == 0 .and. ca(2) == 0 .and. ca(3) == 0) then
      if(iMeanFlow_x=="dynamic") nlk(0,0,0,1) = -fx1 / m_fluid
      if(iMeanFlow_y=="dynamic") nlk(0,0,0,2) = -fy1 / m_fluid
      if(iMeanFlow_z=="dynamic") nlk(0,0,0,3) = -fz1 / m_fluid
    endif
  endif
  
  !-----------------------------------------------------------------------------
  ! forcing that accelerates mean flow from rest to unity and keeps it there
  !-----------------------------------------------------------------------------
  if(iMeanFlow_x=="accelerate_to_unity".or.iMeanFlow_y=="accelerate_to_unity".or.iMeanFlow_z=="accelerate_to_unity") then 
    if (ca(1) == 0 .and. ca(2) == 0 .and. ca(3) == 0) then
      fx = max(0.d0,1.d0-dreal(uk(0,0,0,1)))
      fy = max(0.d0,1.d0-dreal(uk(0,0,0,2)))
      fz = max(0.d0,1.d0-dreal(uk(0,0,0,3)))
      if(iMeanFlow_x=="accelerate_to_unity") nlk(0,0,0,1) = nlk(0,0,0,1) + fx
      if(iMeanFlow_y=="accelerate_to_unity") nlk(0,0,0,2) = nlk(0,0,0,2) + fy
      if(iMeanFlow_z=="accelerate_to_unity") nlk(0,0,0,3) = nlk(0,0,0,3) + fz
    endif
  endif
  
  
  
  time_nlk = time_nlk + MPI_wtime() - t0
end subroutine cal_nlk_fsi



!-------------------------------------------------------------------------------
! Compute the pressure. It is given by the divergence of the non-linear
! terms (nlk: intent(in)) divided by k**2.
! so: p=(i*kx*sxk + i*ky*syk + i*kz*szk) / k**2 
! note: we use rotational formulation: p is NOT the physical pressure
! as the RHS in cal_nlk is on the left side, i.e. -(vor x u) -chi*(u-us)
! its sign is inversed when computing the pressure
!-------------------------------------------------------------------------------
subroutine pressure(nlk,pk)
  use mpi
  use p3dfft_wrapper
  use vars
  implicit none

  integer :: ix,iy,iz
  real(kind=pr) :: kx,ky,kz,k2
  complex(kind=pr),intent(out):: pk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3))
  complex(kind=pr),intent(in):: nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr) :: imag,nlkx,nlky,nlkz

  ! as the RHS in cal_nlk is on the left side, i.e. -(vor x u) -chi*(u-us)
  ! its sign is inversed when computing the pressure
  imag = dcmplx(0.d0,1.d0)
  do ix=ca(3),cb(3)
     kx=wave_x(ix)
     do iy=ca(2),cb(2)
        ky=wave_y(iy)
        do iz=ca(1),cb(1)
           kz=wave_z(iz)
           k2=kx*kx + ky*ky + kz*kz
           if(k2 .ne. 0.0) then
             ! contains the pressure in Fourier space
             ! note "-" sign
             nlkx = nlk(iz,iy,ix,1)
             nlky = nlk(iz,iy,ix,2)
             nlkz = nlk(iz,iy,ix,3)
             pk(iz,iy,ix) = -imag*(kx*nlkx + ky*nlky + kz*nlkz) / k2
           else
             pk(iz,iy,ix) = dcmplx(0.d0,0.d0)
           endif
        enddo
     enddo
  enddo
end subroutine pressure


!-------------------------------------------------------------------------------
! Compute the pressure in an inefficient way given only the velocity
!-------------------------------------------------------------------------------
subroutine pressure_given_uk(time,u,uk,nlk,vort,work,workc,press)
  use mpi
  use p3dfft_wrapper
  use vars
  implicit none

  real(kind=pr), intent(in) :: time
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  complex(kind=pr),intent(inout)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(in)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw) 
  
  call cal_nlk_fsi (time,0,nlk,uk,u,vort,work,workc) 
  call pressure(nlk,workc(:,:,:,1))
  call ifft(ink=workc(:,:,:,1), outx=press(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3)))
  
end subroutine 



!-------------------------------------------------------------------------------
! Add the gradient of the pressure to the nonlinear term, which is the actual
! projection scheme used in this code. The non-linear term comes in with NL and
! penalization and leaves divergence free
!-------------------------------------------------------------------------------
subroutine add_grad_pressure(nlk1,nlk2,nlk3)
  use mpi
  use vars
  use p3dfft_wrapper
  implicit none

  complex(kind=pr),intent(inout):: nlk1(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3))
  complex(kind=pr),intent(inout):: nlk2(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3))
  complex(kind=pr),intent(inout):: nlk3(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3))
  integer :: ix,iy,iz
  real(kind=pr) :: kx,ky,kz,k2
  complex(kind=pr) :: qk, nlx,nly,nlz
  complex(kind=pr) :: imag   ! imaginary unit

  imag = dcmplx(0.d0,1.d0)
  do ix=ca(3),cb(3)
     kx=wave_x(ix)
     do iy=ca(2),cb(2)
        ky=wave_y(iy)
        do iz=ca(1),cb(1)
           kz=wave_z(iz)
           k2=kx*kx + ky*ky + kz*kz
           if (k2 .ne. 0.0) then
              nlx=nlk1(iz,iy,ix)
              nly=nlk2(iz,iy,ix)
              nlz=nlk3(iz,iy,ix)
              ! qk is the Fourier coefficient of thr pressure
              qk=(kx*nlx + ky*nly + kz*nlz)/k2
              ! add the gradient to the non-linear terms
              nlk1(iz,iy,ix)=nlx - kx*qk
              nlk2(iz,iy,ix)=nly - ky*qk
              nlk3(iz,iy,ix)=nlz - kz*qk
           endif
        enddo
     enddo
  enddo
end subroutine add_grad_pressure


! Compute the nonlinear source term of the mhd equations,
! including penality term, in Fourier space.

! Input: ubk, which is a 4D array containing the Fourier-space version
! of the velocity and magnetic field.

! Output: nlk is the (Fourier-space) nonlinear source term for both
! the velocity and magnetic field. ub is the physical-space version of
! the input velocity and magnetic field.

! Work memory: wj is a 4D array which is used to compute the voriticy
! and current density and other quantities, but doesn't contain anything
! useful at the end of the subroutine.

! Other (global) arrays: mask is 3D physical-space array containing
! the mask function for both the velocity and magnetic field. us is a
! 4D array containing the imposed velocity and magnetic field in
! phsyical space.
subroutine cal_nlk_mhd(nlk,ubk,ub,wj)
  use mpi
  use fsi_vars
  use p3dfft_wrapper
  use basic_operators
  use penalization ! mask array etc
  implicit none

  complex(kind=pr),intent(inout) ::ubk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout) ::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  real(kind=pr),intent(inout) :: wj(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout) :: ub(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
   !  real(kind=pr) :: t1,t0
  integer :: i,ix,iy,iz
  real(kind=pr) :: w1,w2,w3,j1,j2,j3
  real(kind=pr) :: u1,u2,u3,b1,b2,b3
  real(kind=pr) :: m,us1,us2,us3

  ! Transform u and B into physical space:
  do i=1,nd
     call ifft(ub(:,:,:,i),ubk(:,:,:,i))
  enddo

  ! Compute us, the imposed penalty field:
  call update_us(ub) ! TODO: only update when necessary

  ! Compute the vorticity and store the result in the first three 3D
  ! arrays of nlk.
  call curl(nlk(:,:,:,1),nlk(:,:,:,2),nlk(:,:,:,3),&
       ubk(:,:,:,1),ubk(:,:,:,2),ubk(:,:,:,3))

  ! Compute the current density and store the result in the last three
  ! 3D arrays of nlk.
  call curl(nlk(:,:,:,4),nlk(:,:,:,5),nlk(:,:,:,6),&
       ubk(:,:,:,4),ubk(:,:,:,5),ubk(:,:,:,6))

  ! Transform vorcitity and current density to physical space, store
  ! in wj
  do i=1,nd
     call ifft(wj(:,:,:,i),nlk(:,:,:,i))
  enddo

  ! Put the x-space version of the nonlinear source term in wj.
  do iz=ra(3),rb(3)
     do iy=ra(2),rb(2)
        do ix=ra(1),rb(1)
           ! Loop-local variables for velocity and magnetic field:
           u1=ub(ix,iy,iz,1)
           u2=ub(ix,iy,iz,2)
           u3=ub(ix,iy,iz,3)
           b1=ub(ix,iy,iz,4)
           b2=ub(ix,iy,iz,5)
           b3=ub(ix,iy,iz,6)

           ! Loop-local variables for vorticity and current density:
           w1=wj(ix,iy,iz,1)
           w2=wj(ix,iy,iz,2)
           w3=wj(ix,iy,iz,3)
           j1=wj(ix,iy,iz,4)
           j2=wj(ix,iy,iz,5)
           j3=wj(ix,iy,iz,6)

           ! Loop-local variables for mask and imposed velocity field:
           m=mask(ix,iy,iz)
           us1=us(ix,iy,iz,1)
           us2=us(ix,iy,iz,2)
           us3=us(ix,iy,iz,3)

            ! Nonlinear source term for fluid, including penalization:
            wj(ix,iy,iz,1)=u2*w3 - u3*w2 + j2*b3 - j3*b2 -m*(u1-us1)
            wj(ix,iy,iz,2)=u3*w1 - u1*w3 + j3*b1 - j1*b3 -m*(u2-us2)
            wj(ix,iy,iz,3)=u1*w2 - u2*w1 + j1*b2 - j2*b1 -m*(u3-us3)

            ! Nonlinear source term for magnetic field (missing the
            ! curl and without penalization):
            wj(ix,iy,iz,4)=u2*b3 - u3*b2
            wj(ix,iy,iz,5)=u3*b1 - u1*b3
            wj(ix,iy,iz,6)=u1*b2 - u2*b1
        enddo
     enddo
  enddo

  ! Transform B to Fourier space.  Keep the first three fields free so
  ! that we can use it to store the penalization for the B field.
  do i=4,nd
     call fft(nlk(:,:,:,i),wj(:,:,:,i))
  enddo
  ! NB: the last three sub-arrays of wj and the first three sub-arrays
  ! of nlk are free.

  ! Add the curl to the magnetic source term:
  call curl(nlk(:,:,:,4),nlk(:,:,:,5),nlk(:,:,:,6))

  ! Penalization for B-field:
  if(iPenalization == 1) then
     do i=4,nd
        wj(:,:,:,4)=-mask*(ub(:,:,:,i) - us(:,:,:,i))
        call fft(nlk(:,:,:,1),wj(:,:,:,4))
        nlk(:,:,:,i)=nlk(:,:,:,i) + nlk(:,:,:,1)
     enddo
  endif
  
  ! Transform u source-term to Fourier space:
  do i=1,3
     call fft(nlk(:,:,:,i),wj(:,:,:,i))
  enddo

  ! NB: wj is now completely free, and contains nothing useful.

  ! Add the gradient of the pseudo-pressure to the source term of the
  ! fluid.
  call add_grad_pressure(nlk(:,:,:,1),nlk(:,:,:,2),nlk(:,:,:,3))

  ! Make the source term for the magnetic field divergence-free via a
  ! Helmholtz decomposition.
  call div_field_nul(nlk(:,:,:,4),nlk(:,:,:,5),nlk(:,:,:,6))
end subroutine cal_nlk_mhd


! Render the input field divergence-free via a Helmholtz
! decomposition. The zero-mode is left untouched.
subroutine div_field_nul(fx,fy,fz)
  use mpi
  use vars
  use p3dfft_wrapper
  implicit none

  complex(kind=pr), intent(inout) :: fx(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3))
  complex(kind=pr), intent(inout) :: fy(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3))
  complex(kind=pr), intent(inout) :: fz(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3))
  integer :: ix, iy, iz
  real(kind=pr) :: kx, ky, kz, k2
  complex(kind=pr) :: val, vx,vy,vz

  do ix=ca(3),cb(3)
     kx=wave_x(ix)
     do iy=ca(2),cb(2)
        ky=wave_y(iy)
        do iz=ca(1),cb(1)
           kz=wave_z(iz)
           
           k2=kx*kx +ky*ky +kz*kz

           if(k2 /= 0.d0) then
              ! val = (k \cdot{} f) / k^2
              vx=fx(iz,iy,ix)
              vy=fy(iz,iy,ix)
              vz=fz(iz,iy,ix)

              val=(kx*vx + ky*vy + kz*vz)/k2

              ! f <- f - k \cdot{} val
              fx(iz,iy,ix)=vx -kx*val
              fy(iz,iy,ix)=vy -ky*val
              fz(iz,iy,ix)=vz -kz*val
           endif
        enddo
     enddo
  enddo
  
end subroutine div_field_nul
