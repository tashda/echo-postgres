import NIOCore

struct AuthenticationStateMachine {
    
    enum State {
        case initialized
        case startupMessageSent
        case passwordAuthenticationSent
        
        case saslInitialResponseSent(SASLAuthenticationManager<SASLMechanism.SCRAM.SHA256>)
        case saslChallengeResponseSent(SASLAuthenticationManager<SASLMechanism.SCRAM.SHA256>)
        case saslFinalReceived

        /// postgres-wire: a Kerberos (GSSAPI/SSPI) token was sent.
        case gssTokenSent(any PostgresGSSAuthenticator)

        case error(PSQLError)
        case authenticated
    }
    
    enum Action {
        case sendStartupMessage(AuthContext)
        case sendPassword(PasswordAuthencationMode, AuthContext)
        case sendSaslInitialResponse(name: String, initialResponse: [UInt8])
        case sendSaslResponse([UInt8])
        /// postgres-wire: a GSSResponse message (the same 'p' message as a SASL response).
        case sendGSSResponse([UInt8])
        case wait
        case authenticated
        
        case reportAuthenticationError(PSQLError)
    }
    
    let authContext: AuthContext
    var state: State
    
    init(authContext: AuthContext) {
        self.authContext = authContext
        self.state = .initialized
    }
    
    mutating func start() -> Action {
        guard case .initialized = self.state else {
            preconditionFailure("Unexpected state")
        }
        self.state = .startupMessageSent
        return .sendStartupMessage(self.authContext)
    }
    
    mutating func authenticationMessageReceived(_ message: PostgresBackendMessage.Authentication) -> Action {
        switch self.state {
        case .startupMessageSent:
            switch message {
            case .ok:
                self.state = .authenticated
                return .authenticated
            case .md5(let salt):
                guard self.authContext.password != nil else {
                    return self.setAndFireError(PSQLError(code: .authMechanismRequiresPassword))
                }
                self.state = .passwordAuthenticationSent
                return .sendPassword(.md5(salt: salt), self.authContext)
            case .plaintext:
                // postgres-wire: like libpq ("no password supplied"), don't send an empty password.
                guard self.authContext.password != nil else {
                    return self.setAndFireError(PSQLError(code: .authMechanismRequiresPassword))
                }
                self.state = .passwordAuthenticationSent
                return .sendPassword(.cleartext, authContext)
            case .kerberosV5:
                return self.setAndFireError(.unsupportedAuthMechanism(.kerberosV5))
            case .scmCredential:
                return self.setAndFireError(.unsupportedAuthMechanism(.scmCredential))
            case .gss, .sspi:
                // postgres-wire: Kerberos through the configured authenticator.
                guard let factory = self.authContext.gssAuthenticatorFactory else {
                    if case .gss = message { return self.setAndFireError(.unsupportedAuthMechanism(.gss)) }
                    return self.setAndFireError(.unsupportedAuthMechanism(.sspi))
                }
                do {
                    let authenticator = try factory()
                    let token = try authenticator.initialToken()
                    self.state = .gssTokenSent(authenticator)
                    return .sendGSSResponse(token)
                } catch {
                    return self.setAndFireError(.sasl(underlying: error))
                }
            case .sasl(let mechanisms):
                guard mechanisms.contains(SASLMechanism.SCRAM.SHA256.name) else {
                    return self.setAndFireError(.unsupportedAuthMechanism(.sasl(mechanisms: mechanisms)))
                }
                
                guard let password = self.authContext.password else {
                    return self.setAndFireError(.authMechanismRequiresPassword)
                }
                
                let saslManager = SASLAuthenticationManager(asClientSpeaking:
                    SASLMechanism.SCRAM.SHA256(username: self.authContext.username, password: { password }))
                
                do {
                    var bytes: [UInt8]?
                    let done = try saslManager.handle(message: nil, sender: { bytes = $0 })
                    // TODO: Gwynne reminds herself to refactor `SASLAuthenticationManager` to
                    //       be async instead of very badly done synchronous.
                    
                    guard let output = bytes, done == false else {
                        preconditionFailure("TODO: SASL auth is always a three step process in Postgres.")
                    }
                    
                    self.state = .saslInitialResponseSent(saslManager)
                    return .sendSaslInitialResponse(name: SASLMechanism.SCRAM.SHA256.name, initialResponse: output)
                } catch {
                    return self.setAndFireError(.sasl(underlying: error))
                }
            case .gssContinue,
                 .saslContinue,
                 .saslFinal:
                return self.setAndFireError(.unexpectedBackendMessage(.authentication(message)))
            }
        case .gssTokenSent(let authenticator):
            switch message {
            case .ok:
                self.state = .authenticated
                return .authenticated
            case .gssContinue(data: var data):
                let input = data.readBytes(length: data.readableBytes) ?? []
                do {
                    guard let token = try authenticator.nextToken(for: input), !token.isEmpty else { return .wait }
                    return .sendGSSResponse(token)
                } catch {
                    return self.setAndFireError(.sasl(underlying: error))
                }
            default:
                return self.setAndFireError(.unexpectedBackendMessage(.authentication(message)))
            }

        case .passwordAuthenticationSent, .saslFinalReceived:
            guard case .ok = message else {
                return self.setAndFireError(.unexpectedBackendMessage(.authentication(message)))
            }
            
            self.state = .authenticated
            return .authenticated
        
        case .saslInitialResponseSent(let saslManager):
            guard case .saslContinue(data: var data) = message else {
                return self.setAndFireError(.unexpectedBackendMessage(.authentication(message)))
            }
            
            let input = data.readBytes(length: data.readableBytes)
            
            do {
                var bytes: [UInt8]?
                let done = try saslManager.handle(message: input, sender: { bytes = $0 })
                
                guard let output = bytes, done == false else {
                    preconditionFailure("TODO: SASL auth is always a three step process in Postgres.")
                }
                
                self.state = .saslChallengeResponseSent(saslManager)
                return .sendSaslResponse(output)
            } catch {
                return self.setAndFireError(.sasl(underlying: error))
            }
            
        case .saslChallengeResponseSent(let saslManager):
            guard case .saslFinal(data: var data) = message else {
                return self.setAndFireError(.unexpectedBackendMessage(.authentication(message)))
            }
            
            let input = data.readBytes(length: data.readableBytes)
            
            do {
                var bytes: [UInt8]?
                let done = try saslManager.handle(message: input, sender: { bytes = $0 })
                
                guard bytes == nil, done == true else {
                    preconditionFailure("TODO: SASL auth is always a three step process in Postgres.")
                }
                
                self.state = .saslFinalReceived
                return .wait
            } catch {
                return self.setAndFireError(.sasl(underlying: error))
            }
        
        case .initialized:
            preconditionFailure("Invalid state")
            
        case .authenticated, .error:
            preconditionFailure("This state machine must not receive messages, after authenticate or error")
        }
    }
    
    mutating func errorReceived(_ message: PostgresBackendMessage.ErrorResponse) -> Action {
        return self.setAndFireError(.server(message))
    }
    
    mutating func errorHappened(_ error: PSQLError) -> Action {
        return self.setAndFireError(error)
    }

    private mutating func setAndFireError(_ error: PSQLError) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("""
                The `AuthenticationStateMachine` must be immidiatly started after creation.
                """)
        case .startupMessageSent,
             .passwordAuthenticationSent,
             .saslInitialResponseSent,
             .saslChallengeResponseSent,
             .saslFinalReceived,
             .gssTokenSent:
            self.state = .error(error)
            return .reportAuthenticationError(error)
        case .authenticated, .error:
            preconditionFailure("""
                This state must not be reached. If the auth state `.isComplete`, the
                ConnectionStateMachine must not send any further events to the substate machine.
                """)
        }
    }

    var isComplete: Bool {
        switch self.state {
        case .authenticated, .error:
            return true
        case .initialized,
             .startupMessageSent,
             .passwordAuthenticationSent,
             .saslInitialResponseSent,
             .saslChallengeResponseSent,
             .saslFinalReceived,
             .gssTokenSent:
            return false
        }
    }
}

extension AuthenticationStateMachine.State: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .initialized:
            return ".initialized"
        case .startupMessageSent:
            return ".startupMessageSent"
        case .passwordAuthenticationSent:
            return ".passwordAuthenticationSent"
        
        case .saslInitialResponseSent(let saslManager):
            return ".saslInitialResponseSent(\(String(reflecting: saslManager)))"
        case .saslChallengeResponseSent(let saslManager):
            return ".saslChallengeResponseSent(\(String(reflecting: saslManager)))"
        case .saslFinalReceived:
            return ".saslFinalReceived"
        case .gssTokenSent:
            return ".gssTokenSent"
        
        case .error(let error):
            return ".error(\(String(reflecting: error)))"
        case .authenticated:
            return ".authenticated"
        }
    }
}
